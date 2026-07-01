# frozen_string_literal: true

# Remove ontology_term_types rows that were added only for the compliance fix form.
# Fix-form field groups now come from rules.yaml (fix_form.field_groups).
# Paired ontology annotation types (cell_type, tissue, assay, etc.) are kept.
class RemoveComplianceOnlyOntologyTermTypes < ActiveRecord::Migration[7.2]
  COMPLIANCE_ONLY_NAMES = %w[
    organism
    title
    schema_version
    schema_reference
    ensembl_release
    ensembl_database
    ensembl_assembly
    tissue_type
    suspension_type
    donor_id
    is_primary_data
  ].freeze

  def up
    ids = select_values(<<~SQL.squish).map(&:to_i)
      SELECT id FROM ontology_term_types
      WHERE name IN (#{COMPLIANCE_ONLY_NAMES.map { |n| quote(n) }.join(', ')})
    SQL
    return if ids.empty?

    id_list = ids.join(', ')

    execute "UPDATE compliance_mappings SET ontology_term_type_id = NULL WHERE ontology_term_type_id IN (#{id_list})"
    execute "UPDATE clas SET ontology_term_type_id = NULL WHERE ontology_term_type_id IN (#{id_list})"
    execute "DELETE FROM ot_projects WHERE ontology_term_type_id IN (#{id_list})"
    execute "DELETE FROM ott_projects WHERE ontology_term_type_id IN (#{id_list})"
    execute <<~SQL.squish
      DELETE FROM ontology_term_types
      WHERE id IN (#{id_list})
    SQL

    sync_ethnicity_cell_ontology_ids
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          'Compliance-only ontology_term_types rows are defined in rules.yaml; re-run earlier migrations to restore.'
  end

  private

  def sync_ethnicity_cell_ontology_ids
    row = select_one("SELECT id, cell_ontology_ids FROM ontology_term_types WHERE name = 'ethnicity' LIMIT 1")
    return unless row

    tags = %w[HANCESTRO AfPO]
    co_ids = select_values(
      "SELECT id FROM cell_ontologies WHERE tag IN (#{tags.map { |t| quote(t) }.join(', ')})"
    ).map(&:to_i)
    return if co_ids.empty?

    existing = row['cell_ontology_ids'].to_s.split(',').map(&:strip).reject(&:blank?).map(&:to_i)
    merged = (existing + co_ids).uniq
    return if merged.sort == existing.sort

    execute <<~SQL.squish
      UPDATE ontology_term_types
      SET cell_ontology_ids = #{quote(merged.join(','))}, updated_at = NOW()
      WHERE id = #{row['id'].to_i}
    SQL
  end
end
