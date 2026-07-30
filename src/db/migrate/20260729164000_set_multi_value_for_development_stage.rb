# frozen_string_literal: true

class SetMultiValueForDevelopmentStage < ActiveRecord::Migration[7.1]
  def up
    execute <<-SQL.squish
      UPDATE ontology_term_types
      SET multi_value = true
      WHERE field_group_id = 'development_stage'
    SQL
  end

  def down
    execute <<-SQL.squish
      UPDATE ontology_term_types
      SET multi_value = false
      WHERE field_group_id = 'development_stage'
    SQL
  end
end
