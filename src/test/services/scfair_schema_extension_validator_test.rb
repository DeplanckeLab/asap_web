# frozen_string_literal: true

require_relative 'test_base_without_fixtures'
require_relative 'spatial_test_helpers'
require_relative 'perturb_test_helpers'

class ScfairSchemaExtensionValidatorTest < TestBaseWithoutFixtures
  include SpatialTestHelpers
  include PerturbTestHelpers

  test 'records extension warnings in warnings list and valid_checks' do
    field_values = {
      'obs/assay_ontology_term_id' => ['EFO:0030059']
    }

    result = Scfair::SchemaExtensionValidator.new(field_values: field_values, format: 'h5ad').call

    assert_equal 2, result[:warnings].size
    assert result[:warnings].any? { |entry| entry[:field] == 'extension.atac' }
    assert result[:warnings].any? { |entry| entry[:field] == 'extension.analysis_json' }
    assert_equal 2, result[:valid_checks].count { |entry| entry[:status] == 'warning' }
  end

  test 'uses file-check warning when analysis_json is absent outside project compliance' do
    result = Scfair::SchemaExtensionValidator.new(
      field_values: { 'obs/assay_ontology_term_id' => ['EFO:0030059'] },
      format: 'h5ad'
    ).call

    warning = result[:warnings].find { |entry| entry[:field] == 'extension.analysis_json' }
    assert_equal 'analysis_json metadata not found (recommended)', warning[:message]
  end

  test 'uses project compliance warning when analysis_json is absent for loom project validation' do
    result = Scfair::SchemaExtensionValidator.new(
      field_values: { '/col_attrs/assay_ontology_term_id' => ['EFO:0030059'] },
      format: 'loom',
      project_compliance: true
    ).call

    warning = result[:warnings].find { |entry| entry[:field] == 'extension.analysis_json' }
    assert_equal 'ASAP will save/update the performed analysis in /attrs/analysis_pipeline at download time.',
                 warning[:message]
  end

  test 'uses project compliance warning when analysis_json is absent for h5ad project validation' do
    result = Scfair::SchemaExtensionValidator.new(
      field_values: { 'obs/assay_ontology_term_id' => ['EFO:0030059'] },
      format: 'h5ad',
      project_compliance: true
    ).call

    warning = result[:warnings].find { |entry| entry[:field] == 'extension.analysis_json' }
    assert_equal 'ASAP will save/update the performed analysis in uns/analysis_pipeline at download time.',
                 warning[:message]
  end

  test 'skips spatial extension when no spatial metadata or assay is present' do
    result = Scfair::SchemaExtensionValidator.new(
      field_values: { 'obs/assay_ontology_term_id' => ['EFO:0009899'] },
      format: 'h5ad'
    ).call

    spatial = result[:valid_checks].find { |entry| entry[:field] == 'extension.spatial' }
    assert_equal 'skipped', spatial[:status]
  end

  test 'requires spatial is_single for spatial assays' do
    result = Scfair::SchemaExtensionValidator.new(
      field_values: {
        'obs/assay_ontology_term_id' => ['EFO:0022857'],
        'uns/spatial/A1/images/hires' => ['__array__']
      },
      format: 'h5ad'
    ).call

    assert result[:errors].any? { |entry| entry[:field].start_with?('extension.spatial') }
    spatial = result[:valid_checks].find { |entry| entry[:field] == 'extension.spatial' }
    assert_equal 'failed', spatial[:status]
  end

  test 'requires visium obs fields only when spatial is_single is true' do
    result = Scfair::SchemaExtensionValidator.new(
      field_values: {
        'obs/assay_ontology_term_id' => ['EFO:0022857'],
        'uns/spatial/is_single' => ['true']
      },
      format: 'h5ad'
    ).call

    message = result[:errors].find { |entry| entry[:field] == 'extension.spatial.obs' }[:message]
    assert_includes message, 'obs/array_row'
    assert_includes message, 'obs/array_col'
    assert_includes message, 'obs/in_tissue'
  end

  test 'does not require visium obs fields when spatial is_single is false' do
    result = Scfair::SchemaExtensionValidator.new(
      field_values: {
        'obs/assay_ontology_term_id' => ['EFO:0022857'],
        'uns/spatial/is_single' => ['false']
      },
      format: 'h5ad'
    ).call

    spatial = result[:valid_checks].find { |entry| entry[:field] == 'extension.spatial' }
    assert_equal 'passed', spatial[:status]
  end

  test 'detects spatial extension from flattened loom metadata' do
    result = Scfair::SchemaExtensionValidator.new(
      field_values: visium_spatial_field_values(format: 'loom'),
      format: 'loom'
    ).call

    spatial = result[:valid_checks].find { |entry| entry[:field] == 'extension.spatial' }
    assert_equal 'passed', spatial[:status]
  end

  test 'skips perturb extension when no perturb metadata is present' do
    result = Scfair::SchemaExtensionValidator.new(
      field_values: { 'obs/assay_ontology_term_id' => ['EFO:0009899'] },
      format: 'h5ad'
    ).call

    perturb = result[:valid_checks].find { |entry| entry[:field] == 'extension.perturb' }
    assert_equal 'skipped', perturb[:status]
  end

  test 'passes valid perturb extension metadata' do
    result = Scfair::SchemaExtensionValidator.new(
      field_values: perturb_field_values(format: 'h5ad'),
      format: 'h5ad'
    ).call

    perturb = result[:valid_checks].find { |entry| entry[:field] == 'extension.perturb' }
    assert_equal 'passed', perturb[:status]
    assert result[:errors].empty?
  end

  test 'requires genetic_perturbation_strategy when genetic_perturbation_id is present' do
    fields = perturb_field_values(format: 'h5ad')
    fields.delete('obs/genetic_perturbation_strategy')

    result = Scfair::SchemaExtensionValidator.new(field_values: fields, format: 'h5ad').call

    assert result[:errors].any? { |entry| entry[:field] == 'extension.perturb.strategy' }
    perturb = result[:valid_checks].find { |entry| entry[:field] == 'extension.perturb' }
    assert_equal 'failed', perturb[:status]
  end

  test 'requires genetic_perturbation_id when uns genetic_perturbations is present' do
    fields = perturb_field_values(format: 'loom')
    fields.delete('/col_attrs/genetic_perturbation_id')
    fields.delete('/col_attrs/genetic_perturbation_strategy')

    result = Scfair::SchemaExtensionValidator.new(field_values: fields, format: 'loom').call

    assert result[:errors].any? { |entry| entry[:field] == 'extension.perturb.obs.id' }
  end

  test 'validates protospacer sequence length and alphabet' do
    fields = perturb_field_values(format: 'h5ad', protospacer: 'ACGT')

    result = Scfair::SchemaExtensionValidator.new(field_values: fields, format: 'h5ad').call

    assert result[:errors].any? { |entry| entry[:message].include?('protospacer_sequence') }
  end

  test 'rejects legacy target_genomic_regions key naming' do
    fields = perturb_field_values(format: 'h5ad')
    fields['uns/genetic_perturbations/guide_a/target_genomic_regions'] = ['1:100-200(+)']

    result = Scfair::SchemaExtensionValidator.new(field_values: fields, format: 'h5ad').call

    assert result[:errors].any? { |entry| entry[:message].include?('unexpected key target_genomic_regions') }
  end
end
