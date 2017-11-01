require 'active_support/concern'

module ActiveRecord
  # == Multi-Table Inheritance
  module MTI
    module Inheritance
      extend ActiveSupport::Concern
      @mti_tableoids = {}

      included do
        scope :discern_inheritance, -> {

        }
      end

      module ClassMethods

        def uses_mti(custom_table_name = nil, inheritance_column = nil)
          self.inheritance_column = inheritance_column

          @uses_mti = true
          @mti_setup = false
          @mti_tableoid_projection = nil
          @tableoid_column = nil
        end

        def using_multi_table_inheritance?(klass = self)
          klass.uses_mti?
        end

        def uses_mti?
          inheritence_check = check_inheritence_of(@table_name) unless @mti_setup
          @uses_mti = inheritence_check if @uses_mti.nil?
          @uses_mti
        end

        def has_tableoid_column?
          @tableoid_column != false
        end

        def mti_tableoid_projection
          @mti_tableoid_projection
        end

        def mti_tableoid_projection=(value)
          @mti_tableoid_projection = value
        end

        private

        def check_inheritence_of(table_name)
          ActiveRecord::MTI.logger.debug "Trying to check inheritance of table with no table name (#{self})" unless table_name
          return nil unless table_name

          ActiveRecord::MTI.logger.debug "Checking inheritance for #{table_name}"

          result = connection.execute <<-SQL
            SELECT EXISTS (
              SELECT 1
              FROM      pg_catalog.pg_inherits AS i
              LEFT JOIN pg_catalog.pg_rewrite  AS r    ON r.ev_class = 'public.#{table_name}'::regclass::oid
              LEFT JOIN pg_catalog.pg_depend   AS d    ON d.objid    = r.oid
              LEFT JOIN pg_catalog.pg_class    AS cl_d ON cl_d.oid   = d.refobjid
              WHERE inhrelid  = COALESCE(cl_d.relname, 'public.#{table_name}')::regclass::oid
              OR    inhparent = COALESCE(cl_d.relname, 'public.#{table_name}')::regclass::oid
            ) AS uses_inheritence;
          SQL

          uses_inheritence = result.try(:first)['uses_inheritence'] == 't'

          register_tableoid(table_name) if uses_inheritence

          @mti_setup = true
          # Some versions of PSQL return {"?column?"=>"t"}
          # instead of {"exists"=>"t"}, so we're saying screw it,
          # just give me the first value of whatever is returned

          # Ensure a boolean is returned
          return uses_inheritence == true
        end

        def register_tableoid(table_name)

          tableoid_query = connection.execute(<<-SQL
            SELECT '#{table_name}'::regclass::oid AS tableoid, (SELECT EXISTS (
              SELECT 1
              FROM   pg_catalog.pg_attribute
              WHERE  attrelid = '#{table_name}'::regclass
              AND    attname  = 'tableoid'
              AND    NOT attisdropped
            )) AS has_tableoid_column
          SQL
          ).first
          tableoid = tableoid_query['tableoid']
          @tableoid_column = tableoid_query['has_tableoid_column'] == 't'

          if (has_tableoid_column?)
            @mti_tableoid_projection = arel_table[:tableoid].as('tableoid')
            ActiveRecord::MTI.logger.debug "#{table_name} has tableoid column! (#{tableoid})"
          else
            @mti_tableoid_projection = nil
          end

          Inheritance.add_mti(tableoid, self)
        end

        # Called by +instantiate+ to decide which class to use for a new
        # record instance. For single-table inheritance, we check the record
        # for a +type+ column and return the corresponding class.
        def discriminate_class_for_record(record)
          if using_multi_table_inheritance?(base_class)
            find_mti_class(record) || base_class
          elsif using_single_table_inheritance?(record)
            find_sti_class(record[inheritance_column])
          else
            super
          end
        end

        # Search descendants for one who's table_name is equal to the returned tableoid.
        # This indicates the class of the record
        def find_mti_class(record)
          if (has_tableoid_column?)
            Inheritance.find_mti(record['tableoid'])
          else
            self
          end
        end

        # Type condition only applies if it's STI, otherwise it's
        # done for free by querying the inherited table in MTI
        def type_condition(table = arel_table)
          if using_multi_table_inheritance?
            nil
          else
            sti_column = table[inheritance_column]
            sti_names  = ([self] + descendants).map { |model| model.sti_name }

            sti_column.in(sti_names)
          end
        end
      end

      def self.add_mti(tableoid, klass)
        @mti_tableoids[tableoid.to_s.to_sym] = klass
      end

      def self.find_mti(tableoid)
        @mti_tableoids[tableoid.to_s.to_sym]
      end

    end
  end
end
