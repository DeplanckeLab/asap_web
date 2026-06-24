# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class ScfairCheckDetailBuilderTest < TestBaseWithoutFixtures
  def check_text(check)
    check.is_a?(Hash) ? check[:text].to_s : check.to_s
  end

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

    refute detail[:checks_performed].any? { |check| check_text(check).include?('uint8') }
    refute detail[:checks_performed].any? { |check| check_text(check).include?('spatial.is_single must be') }
    assert detail[:checks_performed].any? { |check| check_text(check).include?('extension.spatial.structure') }
    assert detail[:checks_performed].any? { |check| check_text(check).include?('extension.spatial.assets') }
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

    refute detail[:checks_performed].any? { |check| check_text(check).include?('See extension.spatial') }
    refute detail[:checks_performed].any? { |check| check_text(check).include?('spatial.is_single must be') }
    assert detail[:checks_performed].any? { |check| check_text(check).include?('images/hires') }
    assert detail[:checks_performed].any? { |check| check_text(check).include?('obsm/spatial') }
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
    assert detail[:checks_performed].any? { |check| check_text(check).include?('is_single') }
    refute detail[:checks_performed].any? { |check| check_text(check).include?('uint8') }
    refute detail[:checks_performed].any? { |check| check_text(check).include?('obsm/spatial') }
    assert detail[:constraints].any? { |row| row[:label] == 'Spatial metadata root' }
    refute detail[:constraints].any? { |row| row[:label] == 'Hires max dimension' }
  end

  test 'includes checks performed for spatial cross-field rules' do
    detail = Scfair::CheckDetailBuilder.call(
      field: 'cross-field.CF-6-spatial-primary-data',
      message: 'Spatial primary-data constraint OK',
      format: 'h5ad'
    )

    assert detail[:checks_performed].any? { |check| check_text(check).include?('is_single') }
    assert detail[:checks_performed].any? { |check| check_text(check).include?('is_primary_data') }
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
    refute detail[:checks_performed].any? { |check| check_text(check).include?('ethnicity') }
    refute detail[:checks_performed].any? { |check| check_text(check).include?('organism_ontology_term_id') }
    assert detail[:checks_performed].any? { |check| check_text(check).include?('non-obsolete') }
  end

  test 'assay allowed_terms checks_performed lists only existence rules not other fields' do
    detail = Scfair::CheckDetailBuilder.call(
      field: 'ontology.semantics.assay_ontology_term_id.allowed_terms',
      message: 'Allowed/known ontology term checks failed',
      format: 'h5ad'
    )

    refute detail[:checks_performed].any? { |check| check_text(check).match?(/ethnicity|organism_ontology_term_id|Descendant|Banned terms/i) }
    assert detail[:checks_performed].any? { |check| check_text(check).include?('non-obsolete') }
  end

  test 'cell type organism-specific checks_performed lists only cell type prefix rules' do
    detail = Scfair::CheckDetailBuilder.call(
      field: 'ontology.organism_specific.cell_type',
      message: 'cell_type_ontology_term_id prefixes are valid for the organism',
      format: 'h5ad'
    )

    assert_equal 'Cell type ontology prefix', detail[:title]
    assert detail[:checks_performed].any? { |check| check_text(check).include?('cell_type_ontology_term_id') }
    refute detail[:checks_performed].any? { |check| check_text(check).match?(/development stage|ethnicity|sex term|tissue_type/i) }
  end

  test 'assay descendants checks_performed lists only root restrictions' do
    detail = Scfair::CheckDetailBuilder.call(
      field: 'ontology.semantics.assay_ontology_term_id.descendants',
      message: 'Descendant/root restriction checks passed',
      format: 'h5ad'
    )

    assert detail[:checks_performed].any? { |check| check_text(check).include?('EFO:0002772') }
    refute detail[:checks_performed].any? { |check| check_text(check).match?(/ethnicity|organism_ontology_term_id|non-obsolete/i) }
  end

  test 'shows only format constraints for ontology format checks' do
    detail = Scfair::CheckDetailBuilder.call(
      field: 'obs/assay_ontology_term_id',
      message: "Ontology terms in obs/assay_ontology_term_id have valid format",
      format: 'h5ad',
      category_id: 'ontology.format'
    )

    assert_equal 'ontology.format', detail[:category_id]
    labels = detail[:constraints].map { |row| row[:label] }
    assert_includes labels, 'Requirement'
    assert_includes labels, 'Allowed prefixes'
    refute_includes labels, 'Cellosaurus format'
    refute labels.any? { |label| label.match?(/Must descend from|Forbidden|Paired label/i) }
    assert detail[:checks_performed].any? { |check| check_text(check).include?('EFO') }
    refute detail[:checks_performed].any? { |check| check_text(check).match?(/CVCL|multiethnic|CL,|UBERON/i) }

    prefixes = detail[:constraints].find { |row| row[:label] == 'Allowed prefixes' }
    assert prefixes[:from_rules]
    assert_equal 'ontology_fields.assay_ontology_term_id.prefixes', prefixes[:rules_path]
    requirement = detail[:constraints].find { |row| row[:label] == 'Requirement' }
    assert requirement[:from_rules]
    assert_equal 'ontology_term_formats.obo.requirement', requirement[:rules_path]
  end

  test 'sex allowed_terms semantic popup lists valid terms from ontology_fields' do
    detail = Scfair::CheckDetailBuilder.call(
      field: 'ontology.semantics.sex_ontology_term_id.allowed_terms',
      message: 'Allowed/known ontology term checks passed',
      format: 'h5ad',
      category_id: 'ontology.semantics'
    )

    allowed = detail[:constraints].find { |row| row[:label] == 'Allowed terms' }
    assert_includes allowed[:value], 'PATO:0001340 (hermaphrodite)'
    assert_equal 'ontology_fields.sex_ontology_term_id.valid_terms', allowed[:rules_path]
  end

  test 'documents cellosaurus format for tissue ontology format checks' do
    detail = Scfair::CheckDetailBuilder.call(
      field: 'obs/tissue_ontology_term_id',
      message: "Ontology terms in obs/tissue_ontology_term_id have valid format",
      format: 'h5ad',
      category_id: 'ontology.format'
    )

    labels = detail[:constraints].map { |row| row[:label] }
    assert_includes labels, 'Cellosaurus format'
    requirement = detail[:constraints].find { |row| row[:label] == 'Requirement' }[:value]
    assert_includes requirement, 'CVCL_*'
    assert detail[:checks_performed].any? { |check| check_text(check).include?('CVCL') }
    refute detail[:checks_performed].any? { |check| check_text(check).include?('multiethnic') }
  end

  test 'ethnicity ontology format checks_performed lists only ethnicity prefixes and specials' do
    detail = Scfair::CheckDetailBuilder.call(
      field: 'obs/self_reported_ethnicity_ontology_term_id',
      message: "Ontology terms in obs/self_reported_ethnicity_ontology_term_id have valid format",
      format: 'h5ad',
      category_id: 'ontology.format'
    )

    assert detail[:checks_performed].any? { |check| check_text(check).include?('HANCESTRO') }
    assert detail[:checks_performed].any? { |check| check_text(check).include?('multiethnic') }
    refute detail[:checks_performed].any? { |check| check_text(check).match?(/CVCL|EFO only|CL,/i) }
  end

  test 'obs presence checks_performed are field-specific' do
    detail = Scfair::CheckDetailBuilder.call(
      field: 'obs/assay_ontology_term_id',
      message: 'Found obs/assay_ontology_term_id metadata',
      format: 'h5ad',
      category_id: 'obs.required_presence'
    )

    assert detail[:checks_performed].any? { |check| check_text(check).include?('obs/assay_ontology_term_id') }
    refute detail[:checks_performed].any? { |check| check_text(check).match?(/tissue_type|donor_id|all observation columns/i) }
  end

  test 'assay database resolution checks_performed lists only assay ontology rules' do
    detail = Scfair::CheckDetailBuilder.call(
      field: 'obs/assay_ontology_term_id',
      message: "EFO:0009899 term not found in ontology DB (valid for 'EFO')",
      format: 'h5ad',
      category_id: 'ontology.database_resolution'
    )

    assert detail[:checks_performed].any? { |check| check_text(check).include?('EFO') }
    assert detail[:checks_performed].any? { |check| check_text(check).include?('obs/assay') }
    refute detail[:checks_performed].any? { |check| check_text(check).match?(/CL,|UBERON|all ontology term/i) }
  end

  test 'shows declarative constraints for required field presence checks' do
    detail = Scfair::CheckDetailBuilder.call(
      field: 'obs/sex_ontology_term_id',
      message: 'Found obs/sex_ontology_term_id metadata',
      format: 'h5ad',
      category_id: 'obs.required_presence'
    )

    assert_equal 'obs.required_presence', detail[:category_id]
    required = detail[:constraints].find { |row| row[:label] == 'Required field' }
    assert required[:from_rules]
    assert required[:rules_path].start_with?('required.obs.')
    assert_equal 'sex_ontology_term_id', required[:value]

    label_pair = detail[:constraints].find { |row| row[:label] == 'Paired label field' }
    assert_equal 'label_pairs.sex_ontology_term_id', label_pair[:rules_path]

    ontology = detail[:constraints].find { |row| row[:label] == 'Ontology field config' }
    assert_equal 'ontology_fields.sex_ontology_term_id', ontology[:rules_path]
  end

  test 'uns field check shows field-specific checks not full uns field list' do
    detail = Scfair::CheckDetailBuilder.call(
      field: 'uns/organism',
      message: 'Missing uns/organism metadata (required by schema)',
      format: 'h5ad',
      category_id: 'uns.required_presence'
    )

    assert_equal 'organism', detail[:title]
    assert_match(/organism name label/, detail[:summary])
    refute detail[:checks_performed].any? { |check| check_text(check).include?('ensembl_release') }
    refute detail[:checks_performed].any? { |check| check_text(check).include?('title') }
    assert detail[:checks_performed].any? { |check| check_text(check).include?('organism_ontology_term_id') }
    required = detail[:constraints].find { |row| row[:label] == 'Required field' }
    assert required[:rules_path].start_with?('required.uns.')
    assert_nil detail[:constraints].find { |row| row[:label] == 'Field metadata' }
  end

  test 'ensembl release constraint comes from rules.yaml field_constraints' do
    detail = Scfair::CheckDetailBuilder.call(
      field: 'uns/ensembl_release',
      message: 'ensembl_release must be a positive integer',
      format: 'h5ad',
      category_id: 'uns.ensembl'
    )

    requirement = detail[:constraints].find { |row| row[:label] == 'Requirement' }
    assert requirement[:from_rules]
    assert_equal 'field_constraints.uns.ensembl_release.0', requirement[:rules_path]
    assert_includes requirement[:value], 'Positive integer'
  end

  test 'metadata.other detail loads title summary and checks from rules.yaml' do
    detail = Scfair::CheckDetailBuilder.call(
      field: 'metadata.other.reserved_prefix',
      message: 'Metadata field names must not start with "__"',
      format: 'h5ad',
      category_id: 'metadata.other'
    )

    assert_equal 'Reserved name prefix', detail[:title]
    assert_includes detail[:summary], '__'
    assert detail[:checks_performed].any? { |check| check_text(check).include?('forbidden "__" prefix') }
  end

  test 'category summary for ontology.format loads from rules.yaml' do
    detail = Scfair::CheckDetailBuilder.call(
      field: 'obs/assay_ontology_term_id',
      message: "Ontology terms in obs/assay_ontology_term_id have valid format",
      format: 'h5ad',
      category_id: 'ontology.format'
    )

    assert_includes detail[:summary], 'PREFIX:ID'
  end

  test 'cross-field CF-3 detail does not include category rollup checks' do
    detail = Scfair::CheckDetailBuilder.call(
      field: 'cross-field.CF-3-donor-id',
      message: 'donor_id consistency OK',
      format: 'h5ad',
      category_id: 'cross-field.constraints'
    )

    assert_equal 'CF-3: donor_id consistency', detail[:title]
    refute detail[:checks_performed].any? { |check| check_text(check).include?('CF-1:') }
    refute detail[:checks_performed].any? { |check| check_text(check).include?('CF-8:') }
    assert detail[:checks_performed].any? { |check| check_text(check).include?('donor_id') }
    assert detail[:constraints].any? { |row| row[:label] == 'Requirement' }
  end

  test 'obs label pair detail loads from label_pairs definition in rules.yaml' do
    detail = Scfair::CheckDetailBuilder.call(
      field: 'obs.label_pairs.assay_ontology_term_id',
      message: 'assay / assay_ontology_term_id pair OK',
      format: 'h5ad',
      category_id: 'obs.label_pairs'
    )

    assert_equal 'assay / assay_ontology_term_id', detail[:title]
    assert_match(/assay label must be present/, detail[:summary])
    assert detail[:constraints].any? { |row| row[:label] == 'Paired label field' && row[:value] == 'assay' }
    assert detail[:checks_performed].any? { |check| check_text(check).include?('label_pairs') }
  end

  test 'cross-field CF-1 detail loads from rules.yaml checks' do
    detail = Scfair::CheckDetailBuilder.call(
      field: 'cross-field.CF-1-assay-suspension',
      message: 'Assay/suspension_type consistency',
      format: 'h5ad',
      category_id: 'cross-field.constraints'
    )

    assert_equal 'CF-1: Assay and suspension_type', detail[:title]
    assert detail[:checks_performed].any? { |check| check_text(check).include?('assay to suspension_type map') }
  end

  test 'ensembl uns field check shows field-specific constraints' do
    detail = Scfair::CheckDetailBuilder.call(
      field: 'uns/ensembl_database',
      message: 'ensembl_database must be one of: Ensembl, EnsemblMetazoa, EnsemblCOVID-19',
      format: 'h5ad',
      category_id: 'uns.ensembl'
    )

    assert_equal 'ensembl_database', detail[:title]
    assert_match(/Ensembl database/, detail[:summary])
    refute detail[:checks_performed].any? { |check| check_text(check).include?('ensembl_release must be') }
    allowed = detail[:constraints].find { |row| row[:label] == 'Allowed values' }
    assert_includes allowed[:value], 'EnsemblMetazoa'
    refute detail[:constraints].any? { |row| row[:label] == 'ensembl_release' }
  end

  test 'enrich_item attaches detail hash' do
    item = Scfair::CheckDetailBuilder.enrich_item(
      { field: 'uns/ensembl_release', message: 'Missing uns/ensembl_release metadata (required by schema)', status: 'failed' },
      format: 'h5ad',
      category_id: 'uns.required_presence'
    )

    assert item[:detail].present?
    assert_equal 'uns.required_presence', item[:detail][:category_id]
    assert_equal item[:message], item[:detail][:result_message]
  end

  test 'uns required presence checks_performed link to rules.yaml lines' do
    detail = Scfair::CheckDetailBuilder.call(
      field: 'uns/ensembl_release',
      message: 'Missing uns/ensembl_release metadata (required by schema)',
      format: 'h5ad',
      category_id: 'uns.required_presence'
    )

    second_check = detail[:checks_performed][1]
    assert_equal 'presence_field_metadata.uns.ensembl_release.extra_checks.0', second_check[:rules_path]
    snippet = Scfair::RulesSnippetExtractor.call(second_check[:rules_path])
    assert_nil snippet[:error]
    assert snippet[:lines].any? { |line| line[:highlight] && line[:text].include?('positive integer') }
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

  test 'var field check shows field-specific checks not full column list' do
    detail = Scfair::CheckDetailBuilder.call(
      field: 'var/feature_biotype',
      message: "feature_biotype must be one of: gene, spike-in (found: unknown)",
      format: 'h5ad',
      category_id: 'var.required'
    )

    assert_equal 'feature_biotype', detail[:title]
    assert_match(/biotype/, detail[:summary])
    refute detail[:checks_performed].any? { |check| check_text(check).include?('feature_chromosome') }
    refute detail[:checks_performed].any? { |check| check_text(check).include?('feature_is_filtered') }
    assert detail[:checks_performed].any? { |check| check_text(check).include?('biotype') }
    allowed = detail[:constraints].find { |row| row[:label] == 'Allowed values' }
    assert_includes allowed[:value], 'gene'
    assert_includes allowed[:value], 'spike-in'
  end

  test 'var field presence check omits constraints and uses field-specific checks' do
    detail = Scfair::CheckDetailBuilder.call(
      field: 'var/feature_chromosome',
      message: 'Missing var/feature_chromosome metadata (required by schema)',
      format: 'h5ad',
      category_id: 'var.required'
    )

    assert_equal 'feature_chromosome', detail[:title]
    assert_match(/Chromosome/i, detail[:summary])
    required = detail[:constraints].find { |row| row[:label] == 'Required field' }
    assert required[:rules_path].start_with?('required.var.')
    refute detail[:checks_performed].any? { |check| check_text(check).include?('feature_biotype') }
    assert detail[:checks_performed].any? { |check| check_text(check).include?('chromosome') }
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

    file_organism = detail[:constraints].find { |row| row[:label] == Scfair::Rules.organism_specific_file_organism_label }
    assert_equal 'NCBITaxon:9606', file_organism[:value]
    assert_equal true, file_organism[:from_file]
    refute file_organism[:from_rules]
    assert_equal 'organism_specific_display.file_organism', file_organism[:rules_path]

    requirement = detail[:constraints].find { |row| row[:label] == 'Requirement' && row[:value].include?('HANCESTRO') }
    assert requirement[:rules_path].start_with?('ontology_semantics_display.organism_specific.self_reported_ethnicity_ontology_term_id._default.human')
    refute detail[:constraints].any? { |row| row[:label] == 'Allowed special values' }
  end

  test 'special_values popup loads check constraints and organism-specific na rule for human ethnicity' do
    detail = Scfair::CheckDetailBuilder.call(
      field: 'ontology.semantics.self_reported_ethnicity_ontology_term_id.special_values',
      message: 'Special placeholder value checks passed',
      format: 'h5ad',
      field_values: {
        'uns/organism_ontology_term_id' => ['NCBITaxon:9606']
      }
    )

    generic = detail[:constraints].find { |row| row[:rules_path] == 'ontology_semantics_display.special_values.constraints.0' }
    assert_match(/Placeholder values/, generic[:value])

    allowed = detail[:constraints].find { |row| row[:label] == 'Allowed special values' }
    assert_equal 'na, unknown, multiethnic', allowed[:value]
    assert_equal 'semantic_rules.self_reported_ethnicity_ontology_term_id.allowed_special_values', allowed[:rules_path]

    na_rule = detail[:constraints].find { |row| row[:label] == 'Requirement' && row[:value].include?('forbidden') }
    assert_equal 'ontology_semantics_display.organism_specific.self_reported_ethnicity_ontology_term_id.special_values.human.2', na_rule[:rules_path]
  end
end
