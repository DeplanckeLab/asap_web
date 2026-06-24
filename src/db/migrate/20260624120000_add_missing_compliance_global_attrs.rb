# frozen_string_literal: true

class AddMissingComplianceGlobalAttrs < ActiveRecord::Migration[7.2]
  def up
    ensembl_db_json = %w[Ensembl EnsemblMetazoa EnsemblCOVID-19].to_json.gsub("'", "''")

    [
      [
        'schema_version', 'Schema Version', 'schema_version',
        'Schema version identifier declared in dataset metadata (must be compatible with scFAIR)',
        'global_attr', 'schema_version', '/attrs/schema_version', 'NULL', 'NULL', 3
      ],
      [
        'schema_reference', 'Schema Reference', 'schema_reference',
        'Canonical URL of the scFAIR schema this file claims to follow',
        'global_attr', 'schema_reference', '/attrs/schema_reference', 'NULL', 'NULL', 4
      ],
      [
        'ensembl_release', 'Ensembl Release', 'ensembl_release',
        'Ensembl release number used for gene annotation (positive integer)',
        'global_attr', 'NULL', '/attrs/ensembl_release', "'115'", 'NULL', 5
      ],
      [
        'ensembl_database', 'Ensembl Database', 'ensembl_database',
        'Ensembl database source used for gene annotation',
        'global_attr', 'NULL', '/attrs/ensembl_database', 'NULL', "'#{ensembl_db_json}'", 6
      ],
      [
        'ensembl_assembly', 'Ensembl Assembly', 'ensembl_assembly',
        'Genome assembly name for the Ensembl annotation (e.g. GRCh38.p14)',
        'global_attr', 'NULL', '/attrs/ensembl_assembly', "'GRCh38.p14'", 'NULL', 7
      ]
    ].each do |name, label, field_group_id, description, field_type, auto_from_project, term_path, term_format_hint, term_valid_values_json, display_order|
      auto_sql = auto_from_project == 'NULL' ? 'NULL' : "'#{auto_from_project}'"
      execute <<~SQL.squish
        INSERT INTO ontology_term_types (
          name, label, field_group_id, description, field_type, auto_from_project,
          term_path, term_format_hint, term_valid_values_json, multi_value, display_order,
          created_at, updated_at
        )
        SELECT
          '#{name}', '#{label}', '#{field_group_id}', '#{description}', '#{field_type}', #{auto_sql},
          '#{term_path}', #{term_format_hint}, #{term_valid_values_json}, false, #{display_order},
          NOW(), NOW()
        WHERE NOT EXISTS (SELECT 1 FROM ontology_term_types WHERE name = '#{name}')
      SQL
    end
  end

  def down
    execute <<~SQL
      DELETE FROM ontology_term_types
      WHERE name IN (
        'schema_version', 'schema_reference',
        'ensembl_release', 'ensembl_database', 'ensembl_assembly'
      )
    SQL
  end
end
