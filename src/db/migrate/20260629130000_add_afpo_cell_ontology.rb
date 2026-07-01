# frozen_string_literal: true

class AddAfpoCellOntology < ActiveRecord::Migration[7.2]
  AFPO_TAG = 'AfPO'

  def up
    afpo = CellOntology.find_or_initialize_by(tag: AFPO_TAG)
    afpo.assign_attributes(
      name: 'African Population Ontology',
      format: 'obo',
      tax_ids: '9606',
      file_url: 'https://raw.githubusercontent.com/h3abionet/afpo/master/afpo.obo',
      url: 'https://www.ebi.ac.uk/ols4/ontologies/afpo',
      latest_version: '2024-03-21',
      obsolete: false
    )
    afpo.save!

    ethnicity = OntologyTermType.find_by(name: 'ethnicity')
    return unless ethnicity

    ids = ethnicity.cell_ontology_ids.to_s.split(',').map(&:strip).reject(&:blank?).map(&:to_i)
    merged = (ids + [afpo.id]).uniq
    return if merged == ids

    ethnicity.update!(cell_ontology_ids: merged.join(','))
  end

  def down
    afpo = CellOntology.find_by(tag: AFPO_TAG)
    return unless afpo

    afpo_id = afpo.id
    execute "DELETE FROM cell_ontology_terms WHERE cell_ontology_id = #{afpo_id}"
    afpo.destroy!

    ethnicity = OntologyTermType.find_by(name: 'ethnicity')
    return unless ethnicity

    ids = ethnicity.cell_ontology_ids.to_s.split(',').map(&:strip).reject(&:blank?).map(&:to_i)
    ids.reject! { |id| id == afpo_id }
    ethnicity.update!(cell_ontology_ids: ids.join(','))
  end
end
