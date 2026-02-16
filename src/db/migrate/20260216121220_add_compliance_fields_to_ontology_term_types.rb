class AddComplianceFieldsToOntologyTermTypes < ActiveRecord::Migration[7.2]
  def up
    # Add new columns for compliance field group configuration.
    # These replace the hardcoded FIELD_GROUPS constant in ComplianceController.
    execute "ALTER TABLE ontology_term_types ADD COLUMN IF NOT EXISTS description text"
    execute "ALTER TABLE ontology_term_types ADD COLUMN IF NOT EXISTS field_type varchar DEFAULT 'col_attr'"
    execute "ALTER TABLE ontology_term_types ADD COLUMN IF NOT EXISTS auto_from_project varchar"
    execute "ALTER TABLE ontology_term_types ADD COLUMN IF NOT EXISTS term_path varchar"
    execute "ALTER TABLE ontology_term_types ADD COLUMN IF NOT EXISTS term_format_hint varchar"
    execute "ALTER TABLE ontology_term_types ADD COLUMN IF NOT EXISTS label_path varchar"
    execute "ALTER TABLE ontology_term_types ADD COLUMN IF NOT EXISTS multi_value boolean DEFAULT false"
    execute "ALTER TABLE ontology_term_types ADD COLUMN IF NOT EXISTS term_valid_values_json text"
    execute "ALTER TABLE ontology_term_types ADD COLUMN IF NOT EXISTS display_order integer DEFAULT 99"

    # --- Update existing records ---

    # cell_type (ott id=1)
    execute <<~SQL
      UPDATE ontology_term_types SET
        description = 'Cell type annotation',
        field_type = 'col_attr',
        term_path = '/col_attrs/cell_type_ontology_term_id',
        term_format_hint = 'CL:XXXXXXX',
        label_path = '/col_attrs/cell_type',
        multi_value = false,
        display_order = 4
      WHERE name = 'cell_type'
    SQL

    # tissue (ott id=2) -- add CVCL (id=16) to cell_ontology_ids
    execute <<~SQL
      UPDATE ontology_term_types SET
        description = 'Tissue of origin',
        field_type = 'col_attr',
        term_path = '/col_attrs/tissue_ontology_term_id',
        term_format_hint = 'UBERON:XXXXXXX',
        label_path = '/col_attrs/tissue',
        multi_value = false,
        display_order = 9,
        cell_ontology_ids = '2,9,14,3,16'
      WHERE name = 'tissue'
    SQL

    # developmental_stage (ott id=3) -- add UBERON (id=3) to cell_ontology_ids
    execute <<~SQL
      UPDATE ontology_term_types SET
        description = 'Developmental stage of the organism',
        field_type = 'col_attr',
        term_path = '/col_attrs/development_stage_ontology_term_id',
        term_format_hint = 'HsapDv:XXXXXXX or "unknown"',
        label_path = '/col_attrs/development_stage',
        multi_value = false,
        display_order = 5,
        cell_ontology_ids = '5,6,8,12,15,3'
      WHERE name = 'developmental_stage'
    SQL

    # disease (ott id=5)
    execute <<~SQL
      UPDATE ontology_term_types SET
        description = 'Disease condition or PATO:0000461 for normal/healthy',
        field_type = 'col_attr',
        term_path = '/col_attrs/disease_ontology_term_id',
        term_format_hint = 'MONDO:XXXXXXX or PATO:0000461 (normal)',
        label_path = '/col_attrs/disease',
        multi_value = true,
        display_order = 6
      WHERE name = 'disease'
    SQL

    # sex (ott id=6)
    execute <<~SQL
      UPDATE ontology_term_types SET
        description = 'Biological sex or "unknown" / "na"',
        field_type = 'col_attr',
        term_path = '/col_attrs/sex_ontology_term_id',
        term_format_hint = 'PATO:0000384 (male), PATO:0000383 (female), or "unknown"',
        label_path = '/col_attrs/sex',
        multi_value = false,
        display_order = 8
      WHERE name = 'sex'
    SQL

    # technology / assay (ott id=7)
    execute <<~SQL
      UPDATE ontology_term_types SET
        description = 'Experimental technique used (e.g., 10x 3'' v3)',
        field_type = 'col_attr',
        term_path = '/col_attrs/assay_ontology_term_id',
        term_format_hint = 'EFO:XXXXXXX',
        label_path = '/col_attrs/assay',
        multi_value = false,
        display_order = 3
      WHERE name = 'technology'
    SQL

    # ethnicity / self_reported_ethnicity (ott id=8)
    execute <<~SQL
      UPDATE ontology_term_types SET
        description = 'Self-reported ethnicity or "unknown" / "na"',
        field_type = 'col_attr',
        term_path = '/col_attrs/self_reported_ethnicity_ontology_term_id',
        term_format_hint = 'HANCESTRO:XXXX or "unknown" or "na"',
        label_path = '/col_attrs/self_reported_ethnicity',
        multi_value = true,
        display_order = 7
      WHERE name = 'ethnicity'
    SQL

    # --- Create new records for field groups not yet in OTT ---

    # organism (auto-filled from project)
    execute <<~SQL
      INSERT INTO ontology_term_types (name, label, field_group_id, description, field_type, auto_from_project, term_path, term_format_hint, label_path, multi_value, display_order, created_at, updated_at)
      VALUES ('organism', 'Organism', 'organism', 'Organism taxonomy -- auto-filled from the project organism', 'global_attr', 'true', '/attrs/organism_ontology_term_id', 'NCBITaxon:9606 (Human), NCBITaxon:10090 (Mouse)', '/attrs/organism', false, 1, NOW(), NOW())
      ON CONFLICT DO NOTHING
    SQL

    # title (auto-filled from project name)
    execute <<~SQL
      INSERT INTO ontology_term_types (name, label, field_group_id, description, field_type, auto_from_project, term_path, label_path, multi_value, display_order, created_at, updated_at)
      VALUES ('title', 'Title', 'title', 'Dataset title -- auto-filled from the project name', 'global_attr', 'title', '/attrs/title', NULL, false, 2, NOW(), NOW())
      ON CONFLICT DO NOTHING
    SQL

    # tissue_type (fixed valid values)
    execute <<~SQL
      INSERT INTO ontology_term_types (name, label, field_group_id, description, field_type, term_path, term_valid_values_json, multi_value, display_order, created_at, updated_at)
      VALUES ('tissue_type', 'Tissue Type', 'tissue_type', 'Type of tissue sample', 'col_attr', '/col_attrs/tissue_type', '["tissue","organoid","cell line","primary cell culture"]', false, 10, NOW(), NOW())
      ON CONFLICT DO NOTHING
    SQL

    # suspension_type (fixed valid values)
    execute <<~SQL
      INSERT INTO ontology_term_types (name, label, field_group_id, description, field_type, term_path, term_valid_values_json, multi_value, display_order, created_at, updated_at)
      VALUES ('suspension_type', 'Suspension Type', 'suspension_type', 'Type of cell suspension', 'col_attr', '/col_attrs/suspension_type', '["cell","nucleus","na"]', false, 11, NOW(), NOW())
      ON CONFLICT DO NOTHING
    SQL

    # donor_id (free text)
    execute <<~SQL
      INSERT INTO ontology_term_types (name, label, field_group_id, description, field_type, term_path, multi_value, display_order, created_at, updated_at)
      VALUES ('donor_id', 'Donor ID', 'donor_id', 'Unique donor identifier', 'col_attr', '/col_attrs/donor_id', false, 12, NOW(), NOW())
      ON CONFLICT DO NOTHING
    SQL

    # is_primary_data (fixed valid values)
    execute <<~SQL
      INSERT INTO ontology_term_types (name, label, field_group_id, description, field_type, term_path, term_valid_values_json, multi_value, display_order, created_at, updated_at)
      VALUES ('is_primary_data', 'Is Primary Data', 'is_primary_data', 'Whether this is the canonical instance of this data (True/False)', 'col_attr', '/col_attrs/is_primary_data', '["True","False"]', false, 13, NOW(), NOW())
      ON CONFLICT DO NOTHING
    SQL
  end

  def down
    execute "ALTER TABLE ontology_term_types DROP COLUMN IF EXISTS description"
    execute "ALTER TABLE ontology_term_types DROP COLUMN IF EXISTS field_type"
    execute "ALTER TABLE ontology_term_types DROP COLUMN IF EXISTS auto_from_project"
    execute "ALTER TABLE ontology_term_types DROP COLUMN IF EXISTS term_path"
    execute "ALTER TABLE ontology_term_types DROP COLUMN IF EXISTS term_format_hint"
    execute "ALTER TABLE ontology_term_types DROP COLUMN IF EXISTS label_path"
    execute "ALTER TABLE ontology_term_types DROP COLUMN IF EXISTS multi_value"
    execute "ALTER TABLE ontology_term_types DROP COLUMN IF EXISTS term_valid_values_json"
    execute "ALTER TABLE ontology_term_types DROP COLUMN IF EXISTS display_order"

    execute "DELETE FROM ontology_term_types WHERE name IN ('organism', 'title', 'tissue_type', 'suspension_type', 'donor_id', 'is_primary_data')"
  end
end
