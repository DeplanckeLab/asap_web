# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class ScfairFixFormFieldSourcesAuditTest < TestBaseWithoutFixtures
  OttStub = Struct.new(:id, :name, :field_group_id, :fg, :cell_ontology_ids, keyword_init: true) do
    def cell_ontology_ids_list
      cell_ontology_ids.to_s.split(',').map(&:strip).reject(&:blank?).map(&:to_i)
    end

    def to_field_group(_co_id_to_tag = nil)
      fg.merge(id: field_group_id, ontology_term_type_id: id)
    end
  end

  test 'builds expected rows from rules.yaml for paired ontology and enum fields' do
    result = Scfair::FixFormFieldSourcesAudit.call(ott_records: [])

    assert_equal 18, result.expected_rows.size
    paths = result.expected_rows.map { |r| r[:term_path] }
    assert_includes paths, '/col_attrs/assay_ontology_term_id'
    assert_includes paths, '/col_attrs/tissue_type'
    assert_includes paths, '/attrs/schema_version'

    assay = result.expected_rows.find { |r| r[:term_field] == 'assay_ontology_term_id' }
    assert_equal :paired_ontology, assay[:classification]
    assert_equal '/col_attrs/assay', assay[:label_path]
    assert_equal %w[EFO], assay[:ontology_prefixes]

    tissue_type = result.expected_rows.find { |r| r[:term_field] == 'tissue_type' }
    assert_equal :enum_obs, tissue_type[:classification]
    assert_equal ['cell line', 'organoid', 'primary cell culture', 'tissue'], tissue_type[:enum_values]

    is_primary = result.expected_rows.find { |r| r[:term_field] == 'is_primary_data' }
    assert_equal %w[False True], is_primary[:enum_values]
  end

  test 'does not require OTT row for auto-fill organism pair' do
    result = Scfair::FixFormFieldSourcesAudit.call(ott_records: [])
    missing_fields = result.missing_from_ott.map { |r| r[:term_field] }

    refute_includes missing_fields, 'organism_ontology_term_id'
    assert_equal 7, result.missing_from_ott.size
  end

  test 'classifies paired ontology OTT rows as A' do
    ott = OttStub.new(
      id: 7,
      name: 'technology',
      field_group_id: 'assay',
      cell_ontology_ids: '1',
      fg: {
        label: 'Assay',
        description: 'Assay',
        type: :col_attr,
        term_path: '/col_attrs/assay_ontology_term_id',
        label_path: '/col_attrs/assay',
        term_ontology_prefixes: %w[EFO],
        term_valid_values: nil,
        multi_value: false,
        auto_from_project: nil
      }
    )

    result = Scfair::FixFormFieldSourcesAudit.call(ott_records: [ott])
    row = result.classifications.first

    assert_equal :paired_ontology, row[:classification]
    assert_equal 'A', row[:classification_code]
    assert_empty result.misplaced_in_ott
  end

  test 'flags enum obs rows as misplaced in ontology_term_types' do
    ott = OttStub.new(
      id: 99,
      name: 'tissue_type',
      field_group_id: 'tissue_type',
      cell_ontology_ids: '',
      fg: {
        label: 'Tissue Type',
        description: 'Type of tissue sample',
        type: :col_attr,
        term_path: '/col_attrs/tissue_type',
        label_path: nil,
        term_ontology_prefixes: [],
        term_valid_values: %w[tissue organoid cell line primary cell culture],
        multi_value: false,
        auto_from_project: nil
      }
    )

    result = Scfair::FixFormFieldSourcesAudit.call(ott_records: [ott])

    assert_equal 1, result.misplaced_in_ott.size
    assert_equal :enum_obs, result.misplaced_in_ott.first[:classification]
    assert result.divergences?
  end

  test 'detects ontology prefix divergence between OTT and rules.yaml' do
    ott = OttStub.new(
      id: 1,
      name: 'cell_type',
      field_group_id: 'cell_type',
      cell_ontology_ids: '1',
      fg: {
        label: 'Cell Type',
        description: 'Cell type',
        type: :col_attr,
        term_path: '/col_attrs/cell_type_ontology_term_id',
        label_path: '/col_attrs/cell_type',
        term_ontology_prefixes: %w[CL],
        term_valid_values: nil,
        multi_value: true,
        auto_from_project: nil
      }
    )

    result = Scfair::FixFormFieldSourcesAudit.call(ott_records: [ott])
    prefix_divergence = result.divergences.find { |d| d[:check] == 'ontology_prefixes' }

    assert prefix_divergence.present?
    assert_equal %w[CL], prefix_divergence[:ott_value]
    assert_equal %w[CL FBbt WBbt ZFA], prefix_divergence[:rules_value]
  end

  test 'format_report includes classification summary and result footer' do
    result = Scfair::FixFormFieldSourcesAudit.call(ott_records: [])
    report = Scfair::FixFormFieldSourcesAudit.format_report(result)

    assert_includes report, 'Fix form field sources audit'
    assert_includes report, '[A] paired ontology'
    assert_includes report, 'Missing from ontology_term_types'
    assert_includes report, 'RESULT:'
  end
end
