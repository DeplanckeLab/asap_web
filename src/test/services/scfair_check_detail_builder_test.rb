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
      field: 'cross-field.CF-3-donor-id',
      message: 'donor_id must not be "na" unless tissue_type is "cell line"',
      format: 'h5ad'
    )

    assert_equal 'CF-3: donor_id consistency', detail[:title]
    assert_match(/donor_id must not be "na"/, detail[:summary])
  end

  test 'extension.spatial rollup avoids duplicating structure and asset detail' do
    detail = Scfair::CheckDetailBuilder.call(
      field: 'extension.spatial',
      message: 'Spatial schema checks passed',
      format: 'h5ad'
    )

    refute detail[:checks_performed].any? { |check| check.include?('uint8') }
    refute detail[:checks_performed].any? { |check| check.include?('spatial.is_single must be') }
    assert detail[:checks_performed].any? { |check| check.include?('extension.spatial.structure') }
    assert detail[:checks_performed].any? { |check| check.include?('extension.spatial.assets') }
    assert detail[:constraints].any? { |row| row[:label] == 'Sub-checks' }
    refute detail[:constraints].any? { |row| row[:label] == 'Hires max dimension' }
  end

  test 'lists full image and obsm checks for extension.spatial.assets' do
    detail = Scfair::CheckDetailBuilder.call(
      field: 'extension.spatial.assets',
      message: 'Spatial image and embedding checks passed',
      format: 'h5ad',
      category_id: 'extension.spatial'
    )

    refute detail[:checks_performed].any? { |check| check.include?('See extension.spatial') }
    refute detail[:checks_performed].any? { |check| check.include?('spatial.is_single must be') }
    assert detail[:checks_performed].any? { |check| check.include?('images/hires') }
    assert detail[:checks_performed].any? { |check| check.include?('obsm/spatial') }
    assert detail[:constraints].any? { |row| row[:label] == 'Hires max dimension' }
    assert detail[:constraints].any? { |row| row[:label] == 'Minimum embedding columns' }
  end

  test 'includes checks performed for spatial extension popups' do
    detail = Scfair::CheckDetailBuilder.call(
      field: 'extension.spatial.structure',
      message: 'Spatial uns structure checks passed',
      format: 'h5ad',
      category_id: 'extension.spatial'
    )

    assert detail[:checks_performed].size >= 3
    assert detail[:checks_performed].any? { |check| check.include?('is_single') }
    refute detail[:checks_performed].any? { |check| check.include?('uint8') }
    refute detail[:checks_performed].any? { |check| check.include?('obsm/spatial') }
    assert detail[:constraints].any? { |row| row[:label] == 'Spatial metadata root' }
    refute detail[:constraints].any? { |row| row[:label] == 'Hires max dimension' }
  end

  test 'includes checks performed for spatial cross-field rules' do
    detail = Scfair::CheckDetailBuilder.call(
      field: 'cross-field.CF-6-spatial-primary-data',
      message: 'Spatial primary-data constraint OK',
      format: 'h5ad'
    )

    assert detail[:checks_performed].any? { |check| check.include?('is_single') }
    assert detail[:checks_performed].any? { |check| check.include?('is_primary_data') }
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

  test 'shows organism-specific applicability for development stage semantic checks' do
    detail = Scfair::CheckDetailBuilder.call(
      field: 'ontology.semantics.development_stage_ontology_term_id.descendants',
      message: 'Descendant/root restriction checks passed',
      format: 'h5ad',
      field_values: {
        'uns/organism_ontology_term_id' => ['NCBITaxon:9606'],
        'uns/organism' => ['Homo sapiens'],
        'obs/development_stage_ontology_term_id' => ['HsapDv:0000095']
      }
    )

    applicable = detail[:constraints].find { |row| row[:label] == 'Organism-specific prefix rules' }
    assert_match(/Applicable/, applicable[:value])
    assert_match(/Organism-specific constraints/, applicable[:value])
  end

  test 'shows organism-specific tissue context in semantic popup' do
    detail = Scfair::CheckDetailBuilder.call(
      field: 'ontology.semantics.tissue_ontology_term_id.descendants',
      message: 'Descendant/root restriction checks passed',
      format: 'h5ad',
      field_values: {
        'uns/organism_ontology_term_id' => ['NCBITaxon:7227'],
        'obs/tissue_type' => ['tissue'],
        'obs/tissue_ontology_term_id' => ['FBbt:10000000']
      }
    )

    prefixes = detail[:constraints].find { |row| row[:label] == 'Allowed tissue prefixes' }
    assert_includes prefixes[:value], 'UBERON:*'
    assert_includes prefixes[:value], 'FBbt:*'
  end

  test 'shows organism-specific ethnicity context in semantic popup' do
    detail = Scfair::CheckDetailBuilder.call(
      field: 'ontology.semantics.self_reported_ethnicity_ontology_term_id.descendants',
      message: 'Descendant/root restriction checks passed',
      format: 'h5ad',
      field_values: {
        'uns/organism_ontology_term_id' => ['NCBITaxon:9606']
      }
    )

    note = detail[:constraints].find { |row| row[:label] == 'Organism-specific rules' }
    assert_match(/Homo sapiens/, note[:value])
  end
end
