# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class ScfairCheckDetailBuilderTest < TestBaseWithoutFixtures
  test 'builds enum field constraints for tissue_type' do
    detail = Scfair::CheckDetailBuilder.call(
      field: 'obs/tissue_type',
      message: 'Invalid value',
      format: 'h5ad'
    )

    assert_equal 'obs.required_presence', detail[:category_id]
    assert_equal 'tissue_type', detail[:title]
    constraint = detail[:constraints].find { |row| row[:label] == 'Allowed values' }
    assert_includes constraint[:value], 'cell line'
  end

  test 'builds schema version detail' do
    detail = Scfair::CheckDetailBuilder.call(
      field: 'uns/schema_version',
      message: 'schema_version minor version 7.0 (7.0.0) is lower than required 7.1 (7.1.0)',
      format: 'h5ad'
    )

    assert_equal 'schema.version', detail[:category_id]
    assert_equal '7.1.0', detail[:schema_version]
    assert detail[:constraints].any? { |row| row[:label] == 'Reference version' }
  end

  test 'builds cross-field rule detail' do
    detail = Scfair::CheckDetailBuilder.call(
      field: 'cross-field.CF-4-donor-id',
      message: 'donor_id must not be "na" unless tissue_type is "cell line"',
      format: 'h5ad'
    )

    assert_equal 'CF-4: donor_id consistency', detail[:title]
    assert_match(/donor_id must not be "na"/, detail[:summary])
  end

  test 'builds banned terms list for semantic banned_terms checks' do
    detail = Scfair::CheckDetailBuilder.call(
      field: 'ontology.semantics.cell_type_ontology_term_id.banned_terms',
      message: 'Banned ontology term checks failed',
      format: 'h5ad'
    )

    assert_equal 'cell_type_ontology_term_id — Banned terms', detail[:title]
    banned = detail[:constraints].find { |row| row[:label] == 'Banned terms' }
    assert_not_nil banned
    assert_includes banned[:value], 'CL:0000003'
    assert_includes banned[:value], 'CL:0001035'
    assert detail[:constraints].any? { |row| row[:label] == 'Banned branches' && row[:value].include?('WBbt:0006803') }
    refute detail[:constraints].any? { |row| row[:label] == 'Must descend from' }
  end

  test 'builds descendants detail without banned term lists' do
    detail = Scfair::CheckDetailBuilder.call(
      field: 'ontology.semantics.cell_type_ontology_term_id.descendants',
      message: 'Descendant/root restriction checks passed',
      format: 'h5ad'
    )

    assert_equal 'cell_type_ontology_term_id — Descendant / root restrictions', detail[:title]
    assert detail[:constraints].any? { |row| row[:label] == 'Must descend from' && row[:value].include?('CL:0000000') }
    refute detail[:constraints].any? { |row| row[:label] == 'Banned terms' }
  end

  test 'builds allowed terms detail without banned term lists' do
    detail = Scfair::CheckDetailBuilder.call(
      field: 'ontology.semantics.cell_type_ontology_term_id.allowed_terms',
      message: 'Allowed/known ontology term checks passed',
      format: 'h5ad'
    )

    assert detail[:constraints].any? { |row| row[:label] == 'Requirement' }
    refute detail[:constraints].any? { |row| row[:label] == 'Banned terms' }
    refute detail[:constraints].any? { |row| row[:label] == 'Must descend from' }
  end

  test 'shows only format constraints for ontology format checks' do
    detail = Scfair::CheckDetailBuilder.call(
      field: 'obs/assay_ontology_term_id',
      message: "Ontology terms in 'assay_ontology_term_id' have valid format",
      format: 'h5ad',
      category_id: 'ontology.format'
    )

    assert_equal 'ontology.format', detail[:category_id]
    labels = detail[:constraints].map { |row| row[:label] }
    assert_includes labels, 'Requirement'
    assert_includes labels, 'Allowed prefixes'
    refute_includes labels, 'Cellosaurus format'
    refute labels.any? { |label| label.match?(/Must descend from|Forbidden|Paired label/i) }
  end

  test 'documents cellosaurus format for tissue ontology format checks' do
    detail = Scfair::CheckDetailBuilder.call(
      field: 'obs/tissue_ontology_term_id',
      message: "Ontology terms in 'tissue_ontology_term_id' have valid format",
      format: 'h5ad',
      category_id: 'ontology.format'
    )

    labels = detail[:constraints].map { |row| row[:label] }
    assert_includes labels, 'Cellosaurus format'
    requirement = detail[:constraints].find { |row| row[:label] == 'Requirement' }[:value]
    assert_includes requirement, 'CVCL_*'
  end

  test 'omits constraints for required field presence checks' do
    detail = Scfair::CheckDetailBuilder.call(
      field: 'obs/sex_ontology_term_id',
      message: 'Required field present',
      format: 'h5ad',
      category_id: 'obs.required_presence'
    )

    assert_equal 'obs.required_presence', detail[:category_id]
    assert_empty detail[:constraints]
  end

  test 'enrich_item attaches detail hash' do
    item = Scfair::CheckDetailBuilder.enrich_item(
      { field: 'uns/ensembl_release', message: 'Missing required dataset metadata field', status: 'failed' },
      format: 'h5ad',
      category_id: 'uns.required_presence'
    )

    assert item[:detail].present?
    assert_equal 'uns.required_presence', item[:detail][:category_id]
    assert_equal item[:message], item[:detail][:result_message]
  end
end
