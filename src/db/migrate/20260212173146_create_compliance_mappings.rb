class CreateComplianceMappings < ActiveRecord::Migration[7.2]
  def change
    create_table :compliance_mappings do |t|
      t.integer :project_id, null: false
      t.string :field_group_id, null: false            # e.g., 'cell_type', 'assay', 'tissue'
      t.string :target_path, null: false               # e.g., '/col_attrs/cell_type_ontology_term_id'
      t.string :action_type, null: false               # 'map_from', 'resolve_paired', 'set_value'
      t.integer :source_annot_id                       # FK to annots
      t.string :source_path                            # e.g., '/col_attrs/transf_annotation'
      t.string :set_value                              # for set_value actions: the constant value
      t.text :resolve_map_json                         # JSON: { "original_value" => "replacement_value" }
      t.datetime :applied_at, null: false

      t.timestamps
    end

    # Track individual term replacements within a mapping (for resolve_paired actions)
    create_table :compliance_term_replacements do |t|
      t.references :compliance_mapping, null: false, foreign_key: true
      t.string :original_value, null: false            # the value in the source metadata
      t.string :replacement_identifier                 # ontology term identifier, e.g., 'CL:0000084'
      t.string :replacement_name                       # ontology term name, e.g., 'T cell'
      t.integer :cell_ontology_term_id                 # FK to cell_ontology_terms

      t.timestamps
    end

    add_index :compliance_mappings, [:project_id, :field_group_id]
    add_index :compliance_term_replacements, :original_value
  end
end
