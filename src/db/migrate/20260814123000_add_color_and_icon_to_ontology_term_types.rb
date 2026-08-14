# frozen_string_literal: true

class AddColorAndIconToOntologyTermTypes < ActiveRecord::Migration[7.2]
  # Legacy OTT names that map to fix_form.field_groups ids.
  LEGACY_NAME_TO_FIELD_GROUP = {
    'developmental_stage' => 'development_stage',
    'technology' => 'assay',
    'ethnicity' => 'self_reported_ethnicity'
  }.freeze

  def up
    execute "ALTER TABLE ontology_term_types ADD COLUMN IF NOT EXISTS color varchar"
    execute "ALTER TABLE ontology_term_types ADD COLUMN IF NOT EXISTS icon varchar"

    OntologyTermType::EXPLORE_STYLES.each do |field_group_id, style|
      execute <<~SQL.squish
        UPDATE ontology_term_types
        SET color = '#{style[:color]}',
            icon = '#{style[:icon]}'
        WHERE field_group_id = '#{field_group_id}'
           OR name = '#{field_group_id}'
      SQL
    end

    LEGACY_NAME_TO_FIELD_GROUP.each do |legacy_name, field_group_id|
      style = OntologyTermType::EXPLORE_STYLES[field_group_id]
      next unless style

      execute <<~SQL.squish
        UPDATE ontology_term_types
        SET color = COALESCE(NULLIF(color, ''), '#{style[:color]}'),
            icon = COALESCE(NULLIF(icon, ''), '#{style[:icon]}'),
            field_group_id = COALESCE(NULLIF(field_group_id, ''), '#{field_group_id}')
        WHERE name = '#{legacy_name}'
      SQL
    end
  end

  def down
    execute "ALTER TABLE ontology_term_types DROP COLUMN IF EXISTS color"
    execute "ALTER TABLE ontology_term_types DROP COLUMN IF EXISTS icon"
  end
end
