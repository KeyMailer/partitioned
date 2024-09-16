require "active_record/insert_all"

#
# Patching {ActiveRecord} to allow specifying the table name as a function of
# attributes.
#
module ActiveRecord
  module Persistence
    module ClassMethods
      def _insert_record(connection, values, returning) # :nodoc:
        primary_key = self.primary_key
        primary_key_value = nil

        if prefetch_primary_key? && primary_key
          values[primary_key] ||= begin
                                    primary_key_value = next_sequence_value
                                    _default_attributes[primary_key].with_cast_value(primary_key_value)
                                  end
        end

        curr_arel_table = self.respond_to?(:dynamic_arel_table) ? self.dynamic_arel_table(values) : nil
        im = Arel::InsertManager.new(curr_arel_table || arel_table)

        with_connection do |c|
          if values.empty?
            im.insert(connection.empty_insert_statement_value(primary_key))
          else
            im.insert(values.transform_keys { |name| arel_table[name] })
          end

          connection.insert(
            im, "#{self} Create", primary_key || false, primary_key_value,
            returning: returning
          )
        end
      end

      def _update_record(values, constraints, curr_arel_table = nil) # :nodoc:
        tmp_arel_table = curr_arel_table || arel_table
        constraints = _substitute_values(constraints, tmp_arel_table)

        default_constraint = build_default_constraint
        constraints << default_constraint if default_constraint

        if current_scope = self.global_current_scope
          constraints << current_scope.where_clause.ast
        end

        um = Arel::UpdateManager.new(tmp_arel_table)
        um.set(values.transform_keys { |name| tmp_arel_table[name] })
        um.wheres = constraints

        with_connection do |c|
          c.update(um, "#{self} Update")
        end
      end

      def _delete_record(constraints, curr_arel_table = nil) # :nodoc:
        tmp_arel_table = curr_arel_table || arel_table
        constraints = _substitute_values(constraints, tmp_arel_table)

        # constraints = constraints.map { |name, value| predicate_builder[name, value] }

        default_constraint = build_default_constraint
        constraints << default_constraint if default_constraint

        if current_scope = self.global_current_scope
          constraints << current_scope.where_clause.ast
        end

        dm = Arel::DeleteManager.new(tmp_arel_table)
        dm.wheres = constraints

        with_connection do |c|
          c.delete(dm, "#{self} Destroy")
        end
      end

      def _substitute_values(values, curr_arel_table)
        values.map do |name, value|
          predicate_builder.build(curr_arel_table[name], value, nil)
        end
      end
    end # module ClassMethods

    def _update_row(attribute_names, attempted_action = "update")
      self.class._update_record(
        attributes_with_values(attribute_names),
        _query_constraints_hash,
        self.respond_to?(:dynamic_arel_table) ? self.dynamic_arel_table : nil
      )
    end

    def _create_record(attribute_names = self.attribute_names)
      attribute_names = attributes_for_create(attribute_names)

      self.class.with_connection do |connection|
        returning_columns = self.class._returning_columns_for_insert(connection)

        returning_values = self.class._insert_record(
          connection,
          attributes_with_values(attribute_names),
          returning_columns
        )

        returning_columns.zip(returning_values).each do |column, value|
          _write_attribute(column, value) if !_read_attribute(column)
        end if returning_values
      end

      @new_record = false
      @previously_new_record = true

      yield(self) if block_given?

      id
    end

    def _delete_row
      self.class._delete_record(
        _query_constraints_hash,
        self.respond_to?(:dynamic_arel_table) ? self.dynamic_arel_table : nil
      )
    end
  end # module Persistence
end # module ActiveRecord