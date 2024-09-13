require "active_record/insert_all"

#
# Patching {ActiveRecord} to allow specifying the table name as a function of
# attributes.
#
module ActiveRecord
  module Persistence
    module ClassMethods
      def _insert_record(values, curr_arel_table = nil) # :nodoc:
        primary_key = self.primary_key
        primary_key_value = nil

        if primary_key && Hash === values
          primary_key_value = values[primary_key]

          if !primary_key_value && prefetch_primary_key?
            primary_key_value = next_sequence_value
            values[primary_key] = primary_key_value
          end
        end

        tmp_arel_table = curr_arel_table || arel_table

        if values.empty?
          im = connection.empty_insert_statement_value(primary_key)
          im.into tmp_arel_table
        else
          im = _substitute_values(values,tmp_arel_table)
        end
      
        # Create an insert statement with Arel
        insert_manager = Arel::InsertManager.new
        insert_manager.into(tmp_arel_table)
        
        insert_data = []
        im.each do |attr, bind|
          insert_data << [attr, bind]
        end
      
        sql, binds = insert_manager.insert(insert_data).to_sql, insert_data.map(&:last)
        
        connection.insert(sql, "#{self} Create", primary_key || false, primary_key_value, nil, binds)
      end

      def _update_record(values, constraints, curr_arel_table = nil) # :nodoc:
        tmp_arel_table = curr_arel_table || arel_table
        constraints = _substitute_values(constraints, tmp_arel_table).map { |attr, bind| attr.eq(bind) }

        um = tmp_arel_table.where(
          constraints.reduce(&:and)
        ).compile_update(_substitute_values(values, tmp_arel_table), primary_key)

        update_data = []
        values.each do |attr, bind|
          update_data << [attr, bind]
        end

        sql, binds = um.to_sql, update_data.map(&:last)

        connection.update(sql, "#{self} Update", binds)
      end

      def _delete_record(constraints, curr_arel_table = nil) # :nodoc:
        tmp_arel_table = curr_arel_table || arel_table
        constraints = _substitute_values(constraints, tmp_arel_table).map { |attr, bind| attr.eq(bind) }

        dm = Arel::DeleteManager.new
        dm.from(tmp_arel_table)
        dm.wheres = constraints

        sql = dm.to_sql
        connection.delete(sql, "#{self} Destroy")
      end

      def _substitute_values(values, tmp_arel_table = nil)
        curr_arel_table = tmp_arel_table || arel_table
        values.map do |name, value|
          attr = curr_arel_table[name]
          bind = predicate_builder.build_bind_attribute(attr.name, value)
          [attr, bind.value_before_type_cast]
        end
      end
    end # module ClassMethods

    def _update_row(attribute_names, attempted_action = "update")
      self.class._update_record(
        attributes_with_values(attribute_names),
        {@primary_key => id_in_database},
        self.respond_to?(:dynamic_arel_table) ? self.dynamic_arel_table : nil
      )
    end

    def _create_record(attribute_names = self.attribute_names)
        attribute_names = attributes_for_create(attribute_names)
  
        new_id = self.class._insert_record(
          attributes_with_values(attribute_names),
          self.respond_to?(:dynamic_arel_table) ? self.dynamic_arel_table : nil
        )
  
        self.id ||= new_id if @primary_key
  
        @new_record = false
        @previously_new_record = true
  
        yield(self) if block_given?
  
        id
    end

    def _delete_row
      self.class._delete_record(
        {@primary_key => id_in_database},
        self.respond_to?(:dynamic_arel_table) ? self.dynamic_arel_table : nil
      )
    end
  end # module Persistence
end # module ActiveRecord