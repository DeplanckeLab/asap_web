# frozen_string_literal: true

class SyncOntologyTermTypeExploreStyles < ActiveRecord::Migration[7.2]
  # Keep DB color/icon in sync with OntologyTermType::EXPLORE_STYLES (sc-fair.org/explore).
  LEGACY_NAME_TO_FIELD_GROUP = {
    'developmental_stage' => 'development_stage',
    'technology' => 'assay',
    'ethnicity' => 'self_reported_ethnicity'
  }.freeze

  def up
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
        SET color = '#{style[:color]}',
            icon = '#{style[:icon]}'
        WHERE name = '#{legacy_name}'
      SQL
    end
  end

  def down
    # Irreversible palette sync; previous values were the prior EXPLORE_STYLES seed.
  end
end
