# frozen_string_literal: true

require 'minitest/mock'
require_relative 'test_base_without_fixtures'

class ScfairConsensusOfficialMetadataValidatorTest < TestBaseWithoutFixtures
  WARNING_SNIPPET = 'is not the final scFAIR official annotation'

  setup do
    @loom_path = File.join(Dir.tmpdir, "consensus_official_#{SecureRandom.hex(8)}.loom")
    File.write(@loom_path, 'loom-stub')
  end

  teardown do
    File.delete(@loom_path) if @loom_path && File.exist?(@loom_path)
  end

  test 'skips when not project compliance' do
    result = validator(
      project_compliance: false,
      field_values: field_values_with(%w[_asap_consensus_cell_type cell_type])
    ).call

    assert_empty result[:warnings]
  end

  test 'skips when format is not loom' do
    result = validator(
      format: 'h5ad',
      field_values: field_values_with(%w[_asap_consensus_cell_type cell_type])
    ).call

    assert_empty result[:warnings]
  end

  test 'adds warning when consensus and official label vectors differ' do
    ott = ott_stub(
      name: 'cell_type',
      label_path: '/col_attrs/cell_type',
      term_path: '/col_attrs/cell_type_ontology_term_id'
    )

    OntologyTermType.stub(:all, [ott]) do
      H5DataService.stub(:compare_metadata_vector_pairs, lambda { |_path, pairs|
        assert_equal 1, pairs.size
        [
          {
            'a' => 'col_attrs/_asap_consensus_cell_type',
            'b' => 'col_attrs/cell_type',
            'equal' => false,
            'missing' => false
          }
        ]
      }) do
        result = validator(
          field_values: field_values_with(%w[_asap_consensus_cell_type cell_type cell_type_ontology_term_id])
        ).call

        assert_equal 1, result[:warnings].size
        warning = result[:warnings].first
        assert_equal '/col_attrs/cell_type', warning[:field]
        assert_match(/cell_type metadata/, warning[:message])
        assert_match(WARNING_SNIPPET, warning[:message])
        assert_match(/Edit Metadata/, warning[:message])
      end
    end
  end

  test 'maps ethnicity consensus tag to self_reported_ethnicity official field' do
    ott = ott_stub(
      name: 'ethnicity',
      label_path: '/col_attrs/self_reported_ethnicity',
      term_path: '/col_attrs/self_reported_ethnicity_ontology_term_id'
    )

    OntologyTermType.stub(:all, [ott]) do
      H5DataService.stub(:compare_metadata_vector_pairs, lambda { |_path, pairs|
        assert_equal(
          ['col_attrs/_asap_consensus_ethnicity', 'col_attrs/self_reported_ethnicity'],
          [pairs.first[:a].sub(%r{\A/}, ''), pairs.first[:b].sub(%r{\A/}, '')]
        )
        [
          {
            'a' => 'col_attrs/_asap_consensus_ethnicity',
            'b' => 'col_attrs/self_reported_ethnicity',
            'equal' => false,
            'missing' => false
          }
        ]
      }) do
        result = validator(
          field_values: field_values_with(%w[_asap_consensus_ethnicity self_reported_ethnicity])
        ).call

        assert_equal 1, result[:warnings].size
        assert_equal '/col_attrs/self_reported_ethnicity', result[:warnings].first[:field]
        assert_match(/self_reported_ethnicity metadata/, result[:warnings].first[:message])
      end
    end
  end

  test 'does not warn when consensus and official vectors match' do
    ott = ott_stub(
      name: 'cell_type',
      label_path: '/col_attrs/cell_type',
      term_path: '/col_attrs/cell_type_ontology_term_id'
    )

    OntologyTermType.stub(:all, [ott]) do
      H5DataService.stub(:compare_metadata_vector_pairs, lambda { |_path, _pairs|
        [
          {
            'a' => 'col_attrs/_asap_consensus_cell_type',
            'b' => 'col_attrs/cell_type',
            'equal' => true,
            'missing' => false
          }
        ]
      }) do
        result = validator(
          field_values: field_values_with(%w[_asap_consensus_cell_type cell_type])
        ).call

        assert_empty result[:warnings]
      end
    end
  end

  test 'ignores backup consensus columns' do
    OntologyTermType.stub(:all, []) do
      called = false
      H5DataService.stub(:compare_metadata_vector_pairs, lambda { |_path, _pairs|
        called = true
        []
      }) do
        result = validator(
          field_values: field_values_with(%w[_asap_consensus_cell_type.bkp.1 cell_type])
        ).call

        assert_equal false, called
        assert_empty result[:warnings]
      end
    end
  end

  test 'warns when only ontology term id vectors differ' do
    ott = ott_stub(
      name: 'cell_type',
      label_path: '/col_attrs/cell_type',
      term_path: '/col_attrs/cell_type_ontology_term_id'
    )

    OntologyTermType.stub(:all, [ott]) do
      H5DataService.stub(:compare_metadata_vector_pairs, lambda { |_path, pairs|
        assert_equal 2, pairs.size
        [
          {
            'a' => 'col_attrs/_asap_consensus_cell_type',
            'b' => 'col_attrs/cell_type',
            'equal' => true,
            'missing' => false
          },
          {
            'a' => 'col_attrs/_asap_consensus_cell_type_ontology_term_id',
            'b' => 'col_attrs/cell_type_ontology_term_id',
            'equal' => false,
            'missing' => false
          }
        ]
      }) do
        result = validator(
          field_values: field_values_with(
            %w[
              _asap_consensus_cell_type
              _asap_consensus_cell_type_ontology_term_id
              cell_type
              cell_type_ontology_term_id
            ]
          )
        ).call

        assert_equal 1, result[:warnings].size
        assert_equal '/col_attrs/cell_type', result[:warnings].first[:field]
      end
    end
  end

  private

  def validator(field_values:, format: 'loom', project_compliance: true)
    Scfair::ConsensusOfficialMetadataValidator.new(
      file_path: @loom_path,
      field_values: field_values,
      format: format,
      project_compliance: project_compliance
    )
  end

  def field_values_with(columns)
    { 'metadata/obs/columns' => columns }
  end

  def ott_stub(name:, label_path:, term_path:)
    Struct.new(:name, :label_path, :term_path).new(name, label_path, term_path)
  end
end
