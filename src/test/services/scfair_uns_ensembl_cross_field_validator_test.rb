# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class ScfairUnsEnsemblCrossFieldValidatorTest < TestBaseWithoutFixtures
  AssemblyStub = Struct.new(:name, :first_ensembl_release, :latest_ensembl_release, keyword_init: true)

  LookupStub = Struct.new(:remote_available, :assemblies, keyword_init: true) do
    def remote_available?
      remote_available
    end

    def assemblies_for_tax_id(_tax_id)
      assemblies
    end

    def release_supported_by_organism?(_tax_id, release)
      assemblies.any? do |assembly|
        release >= assembly.first_ensembl_release.to_i &&
          (assembly.latest_ensembl_release.blank? || release <= assembly.latest_ensembl_release.to_i)
      end
    end

    def matching_assemblies(assemblies, reported_name, release: nil)
      assemblies.select do |assembly|
        assembly.name == reported_name &&
          (release.blank? || (release >= assembly.first_ensembl_release && release <= assembly.latest_ensembl_release))
      end
    end

    def assembly_matches_name?(assemblies, reported_name)
      assemblies.any? { |assembly| assembly.name == reported_name }
    end
  end

  test 'passes when release is supported by organism assemblies' do
    lookup = LookupStub.new(
      remote_available: true,
      assemblies: [AssemblyStub.new(name: 'GRCh38.p14', first_ensembl_release: 110, latest_ensembl_release: 115)]
    )
    result = Scfair::UnsEnsemblCrossFieldValidator.new(
      field_values: {
        'uns/organism_ontology_term_id' => ['NCBITaxon:9606'],
        'uns/ensembl_release' => ['114']
      },
      format: 'h5ad',
      lookup: lookup
    ).call

    check = result[:valid_checks].find { |entry| entry[:field] == 'cross-field.uns_ensembl.release' }
    assert_equal 'passed', check[:status]
  end

  test 'fails when assembly does not match release' do
    lookup = LookupStub.new(
      remote_available: true,
      assemblies: [AssemblyStub.new(name: 'GRCh38.p14', first_ensembl_release: 110, latest_ensembl_release: 112)]
    )
    result = Scfair::UnsEnsemblCrossFieldValidator.new(
      field_values: {
        'uns/organism_ontology_term_id' => ['NCBITaxon:9606'],
        'uns/ensembl_release' => ['114'],
        'uns/ensembl_assembly' => ['GRCh38.p14']
      },
      format: 'h5ad',
      lookup: lookup
    ).call

    assert result[:errors].any? { |entry| entry[:field] == 'cross-field.uns_ensembl.assembly' }
  end
end
