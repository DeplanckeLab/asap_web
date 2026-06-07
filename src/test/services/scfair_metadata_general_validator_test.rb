# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class ScfairMetadataGeneralValidatorTest < TestBaseWithoutFixtures
  CHECK = 'metadata.other'

  test 'passes when column names satisfy all general metadata rules' do
    result = Scfair::MetadataGeneralValidator.new(
      field_values: valid_field_values,
      format: 'h5ad'
    ).call

    assert_empty result[:errors]
    assert result[:valid_checks].none? { |entry| entry[:field] == CHECK }
    assert result[:valid_checks].any? { |entry| entry[:field] == "#{CHECK}.reserved_prefix" && entry[:status] == 'passed' }
    assert result[:valid_checks].any? { |entry| entry[:field] == "#{CHECK}.deprecated" && entry[:status] == 'passed' }
  end

  test 'fails when obs column name starts with forbidden prefix' do
    field_values = valid_field_values.merge(
      'metadata/obs/columns' => %w[assay_ontology_term_id __reserved_field]
    )

    result = Scfair::MetadataGeneralValidator.new(field_values: field_values, format: 'h5ad').call

    assert result[:errors].any? { |entry| entry[:field] == "#{CHECK}.reserved_prefix" }
    assert_match(/__/, result[:errors].first[:message])
  end

  test 'fails when deprecated obs field is present' do
    field_values = valid_field_values.merge(
      'metadata/obs/columns' => %w[assay_ontology_term_id ethnicity]
    )

    result = Scfair::MetadataGeneralValidator.new(field_values: field_values, format: 'h5ad').call

    assert result[:errors].any? { |entry| entry[:field] == "#{CHECK}.deprecated" }
    assert_match(/ethnicity/, result[:errors].first[:message])
  end

  test 'fails when deprecated uns field is present' do
    field_values = valid_field_values.merge(
      'metadata/uns/columns' => %w[title schema_version version]
    )

    result = Scfair::MetadataGeneralValidator.new(field_values: field_values, format: 'h5ad').call

    assert result[:errors].any? { |entry| entry[:field] == "#{CHECK}.deprecated" }
    assert_match(/version/, result[:errors].first[:message])
  end

  test 'fails when duplicate obs column names are listed' do
    field_values = valid_field_values.merge(
      'metadata/obs/columns' => %w[donor_id donor_id assay_ontology_term_id]
    )

    result = Scfair::MetadataGeneralValidator.new(field_values: field_values, format: 'h5ad').call

    assert result[:errors].any? { |entry| entry[:field] == "#{CHECK}.unique_names.obs" }
    assert_match(/donor_id/, result[:errors].first[:message])
  end

  test 'skips when column lists are unavailable' do
    result = Scfair::MetadataGeneralValidator.new(field_values: {}, format: 'loom').call

    assert result[:valid_checks].none? { |entry| entry[:field] == CHECK }
    assert result[:valid_checks].all? { |entry| entry[:status] == 'skipped' }
    assert_empty result[:errors]
  end

  test 'compliance grouper routes metadata.other checks to Other checks category' do
    catalog = Scfair::Rules.checks_for('h5ad')
    assert catalog.any? { |entry| entry[:id] == CHECK && entry[:label] == 'Other checks' }

    valid_checks = [
      { field: "#{CHECK}.reserved_prefix", status: 'passed', message: 'No forbidden prefix' },
      { field: "#{CHECK}.deprecated", status: 'passed', message: 'No deprecated names' }
    ]

    groups = Scfair::ComplianceReportGrouper.call(
      checks_catalog: catalog,
      valid_checks: valid_checks,
      errors: [],
      warnings: [],
      format: 'h5ad'
    )

    group = groups.find { |entry| entry[:id] == CHECK }
    assert_not_nil group
    assert_equal 'Other checks', group[:label]
    assert_equal 2, group[:items].size
  end

  private

  def valid_field_values
    {
      'metadata/obs/columns' => %w[
        assay assay_ontology_term_id cell_type cell_type_ontology_term_id donor_id
        is_primary_data self_reported_ethnicity self_reported_ethnicity_ontology_term_id
        sex sex_ontology_term_id suspension_type tissue tissue_ontology_term_id tissue_type
      ],
      'metadata/var/columns' => %w[feature_id feature_name feature_biotype],
      'metadata/uns/columns' => %w[title organism organism_ontology_term_id schema_version]
    }
  end
end
