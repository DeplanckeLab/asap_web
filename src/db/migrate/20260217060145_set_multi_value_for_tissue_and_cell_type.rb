class SetMultiValueForTissueAndCellType < ActiveRecord::Migration[7.2]
  def up
    # tissue_ontology_term_id and cell_type_ontology_term_id can contain
    # multi-value entries (separated by ||) per the CELLxGENE schema.
    execute <<~SQL
      UPDATE ontology_term_types
      SET multi_value = true
      WHERE name IN ('tissue', 'cell_type')
        AND field_group_id IS NOT NULL
    SQL
  end

  def down
    execute <<~SQL
      UPDATE ontology_term_types
      SET multi_value = false
      WHERE name IN ('tissue', 'cell_type')
        AND field_group_id IS NOT NULL
    SQL
  end
end
