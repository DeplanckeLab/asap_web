# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class ScfairRulesValidationMessagesTest < TestBaseWithoutFixtures
  test 'obs label pair fields load from label_pairs in rules.yaml' do
    fields = Scfair::Rules.obs_label_pair_fields
    assert_equal 7, fields.size
    assert_equal 'assay', fields['assay_ontology_term_id']
    refute fields.key?('organism_ontology_term_id')
    assert_equal 'obs.label_pairs.assay_ontology_term_id', Scfair::Rules.obs_label_pair_check_field('assay_ontology_term_id')
  end

  test 'sex valid terms and special values load from ontology_fields in rules.yaml' do
    terms = Scfair::Rules.valid_sex_terms
    assert_equal 'female', terms['PATO:0000383']
    assert_equal %w[unknown na], Scfair::Rules.sex_special_values

    semantic = Scfair::Rules.semantic_rules_for('sex_ontology_term_id')
    assert_equal terms, semantic[:allowed_exact]
    assert_equal %w[unknown na], semantic[:allowed_special_values]
    assert_includes Scfair::Rules.semantic_field_names, 'sex_ontology_term_id'
  end

  test 'cell type banned terms load from ontology_fields in rules.yaml' do
    banned = Scfair::Rules.banned_cell_type_terms
    assert_equal %w[CL:0000003 CL:0000255 CL:0000548 CL:0001035], banned

    semantic = Scfair::Rules.semantic_rules_for('cell_type_ontology_term_id')
    assert_equal banned, semantic[:forbidden_exact]
  end

  test 'anndata index translations load from rules.yaml' do
    var = Scfair::Rules.var_index_config
    assert_equal 'var.index', var[:schema]
    assert_equal 'var/_index', var[:h5ad][:path]
    assert_equal %w[_index index], var[:h5ad][:storage_keys]
    assert_equal '/row_attrs/feature_id', var[:loom][:path]
    assert_equal 'var_index_key', var[:loom][:manifest_key]

    obs = Scfair::Rules.anndata_index(:obs)
    assert_equal 'obs.index', obs[:schema]
    assert_equal 'obs/_index', obs[:h5ad][:path]
  end

  test 'cross-field cell line checks load from rules.yaml' do
    checks = Scfair::Rules.cross_field_cell_line_checks
    assert checks.size >= 6
    ethnicity = checks.find { |entry| entry[:id] == 'CF-2a-cell-line-ethnicity' }
    assert_equal 'self_reported_ethnicity_ontology_term_id', ethnicity[:token]
    assert_includes ethnicity[:fail], 'must be "na"'
  end

  test 'cross-field violation messages use yaml templates' do
    violation = Scfair::Rules.cross_field_violation_message(
      'CF-1',
      format: 'h5ad',
      assay: 'EFO:0009899',
      allowed: 'cell, nucleus',
      value: 'na'
    )

    assert_equal 'obs/suspension_type', violation[:field]
    assert_includes violation[:message], 'EFO:0009899'
    assert_includes violation[:message], 'cell, nucleus'
  end

  test 'organism-specific skip messages load from rules.yaml' do
    message = Scfair::Rules.organism_specific_skip_message('sex', :not_celegans)
    assert_includes message, 'C. elegans'
  end

  test 'file organism display metadata loads from rules.yaml' do
    assert_equal 'File organism', Scfair::Rules.organism_specific_file_organism_label
    assert_includes Scfair::Rules.organism_specific_file_organism_source, 'organism_ontology_term_id'
  end

  test 'ontology semantics organism-specific constraints load by check name' do
    entries = Scfair::Rules.ontology_semantics_organism_specific_entries(
      'self_reported_ethnicity_ontology_term_id',
      'special_values',
      variant: :human
    )
    assert_equal 3, entries.size
    assert_equal '"na" is forbidden for Homo sapiens', entries.last[:value].to_s
    assert_equal '_default', Scfair::Rules.ontology_semantics_organism_specific_check_key(
      'self_reported_ethnicity_ontology_term_id',
      'descendants'
    )
  end

  test 'obs layer field checks load from rules.yaml with format paths' do
    checks = Scfair::Rules.layer_field_checks(:obs, 'assay_ontology_term_id', format: 'h5ad')
    assert_equal 1, checks.size
    assert_includes checks.first, 'obs/assay_ontology_term_id'

    loom_checks = Scfair::Rules.layer_field_checks(:obs, 'tissue_type', format: 'loom')
    assert_includes loom_checks.first, '/col_attrs/tissue_type'
    assert_includes loom_checks.last, 'tissue, organoid, cell line, primary cell culture'
  end

  test 'presence message patterns match required field messages' do
    assert Scfair::Rules.message_matches_pattern?(:presence, 'Required field present')
    assert Scfair::Rules.message_matches_pattern?(:presence, 'Missing required dataset metadata field')
    assert Scfair::Rules.message_matches_pattern?(:ontology_format, 'Invalid ontology term format')
  end
end
