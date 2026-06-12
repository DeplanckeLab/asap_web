# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class ScfairVarCrossFieldValidatorTest < TestBaseWithoutFixtures
  LookupStub = Struct.new(
    :remote_available,
    :remote_organism,
    :gene_statuses,
    :genes_by_reference_index,
    keyword_init: true
  ) do
    def remote_available?
      remote_available
    end

    def remote_organism_for_tax_id(_tax_id)
      remote_organism
    end

    def gene_status_at_release(organism_id:, release:, symbol: nil, ensembl_id: nil)
      key = symbol || ensembl_id
      gene_statuses.fetch(key, :ok)
    end

    def known_gene_reference_taxon?(reference)
      reference != Scfair::EnsemblReferenceLookup::SPIKE_IN_TAXON &&
        Scfair::Rules.feature_reference_taxa.key?(reference)
    end

    def allowed_feature_reference?(reference, biotype:)
      case biotype.to_s
      when 'spike-in'
        reference == Scfair::EnsemblReferenceLookup::SPIKE_IN_TAXON
      when 'gene'
        known_gene_reference_taxon?(reference)
      else
        Scfair::Rules.feature_reference_taxa.key?(reference)
      end
    end

    def feature_reference_taxa
      Scfair::Rules.feature_reference_taxa
    end

    def gene_for_reference_and_index(feature_reference, index_id)
      return nil unless remote_available?

      (genes_by_reference_index || {})[[feature_reference, index_id]]
    end

    def expected_feature_name(feature_reference:, index_id:, biotype:)
      index = index_id.to_s.strip
      return nil if index.blank?

      case biotype.to_s
      when 'spike-in'
        spike_in_feature_name_for_index(index)
      when 'gene'
        normalized_index = normalize_ensembl_id(index)
        return normalized_index unless remote_available?

        gene = gene_for_reference_and_index(feature_reference, index)
        gene&.name.presence || normalized_index
      end
    end

    def spike_in_feature_name_for_index(index_id)
      "#{index_id} (spike-in control)"
    end

    def spike_in_feature_name_format_valid?(value)
      value.to_s.match?(/\AERCC-\d+ \(spike-in control\)\z/i)
    end

    def normalize_ensembl_id(value)
      value.to_s.sub(/\.\d+\z/, '')
    end
  end

  test 'passes when feature_reference matches schema taxa and organism' do
    lookup = LookupStub.new(remote_available: false, remote_organism: nil, gene_statuses: {})
    result = Scfair::VarCrossFieldValidator.new(
      field_values: {
        'uns/organism_ontology_term_id' => ['NCBITaxon:9606'],
        'uns/ensembl_release' => ['114'],
        'var/feature_biotype#series' => %w[gene spike-in],
        'var/feature_reference#series' => ['NCBITaxon:9606', 'NCBITaxon:32630']
      },
      format: 'h5ad',
      lookup: lookup
    ).call

    check = result[:valid_checks].find { |entry| entry[:field] == 'var.cross_field.feature_reference' }
    assert_equal 'passed', check[:status]
    refute result[:errors].any? { |entry| entry[:field] == 'var.cross_field.feature_reference' }
  end

  test 'fails when gene feature_reference does not match organism' do
    lookup = LookupStub.new(remote_available: false, remote_organism: nil, gene_statuses: {})
    result = Scfair::VarCrossFieldValidator.new(
      field_values: {
        'uns/organism_ontology_term_id' => ['NCBITaxon:9606'],
        'uns/ensembl_release' => ['114'],
        'var/feature_biotype#series' => %w[gene],
        'var/feature_reference#series' => ['NCBITaxon:10090']
      },
      format: 'h5ad',
      lookup: lookup
    ).call

    error = result[:errors].find { |entry| entry[:field] == 'var.cross_field.feature_reference' }
    assert_not_nil error
    assert_match(/organism_ontology_term_id/, error[:message])
  end

  test 'passes when feature_name matches var index per schema' do
    lookup = LookupStub.new(
      remote_available: true,
      remote_organism: Struct.new(:id).new(1),
      gene_statuses: {},
      genes_by_reference_index: {
        ['NCBITaxon:9606', 'ENSG00000141510'] => Struct.new(:name).new('TP53')
      }
    )
    result = Scfair::VarCrossFieldValidator.new(
      field_values: {
        'var/feature_biotype#series' => %w[gene spike-in],
        'var/feature_reference#series' => ['NCBITaxon:9606', 'NCBITaxon:32630'],
        'var/feature_name#series' => ['TP53', 'ERCC-00003 (spike-in control)'],
        'var/_index#series' => %w[ENSG00000141510 ERCC-00003]
      },
      format: 'h5ad',
      lookup: lookup
    ).call

    check = result[:valid_checks].find { |entry| entry[:field] == 'var.cross_field.feature_name.index' }
    assert_equal 'passed', check[:status]
  end

  test 'gene feature_name defaults to var index when gene_name is absent in reference' do
    lookup = LookupStub.new(remote_available: true, remote_organism: Struct.new(:id).new(1), gene_statuses: {}, genes_by_reference_index: {})
    result = Scfair::VarCrossFieldValidator.new(
      field_values: {
        'var/feature_biotype#series' => %w[gene],
        'var/feature_reference#series' => ['NCBITaxon:9606'],
        'var/feature_name#series' => %w[ENSG00000141510],
        'var/_index#series' => %w[ENSG00000141510]
      },
      format: 'h5ad',
      lookup: lookup
    ).call

    check = result[:valid_checks].find { |entry| entry[:field] == 'var.cross_field.feature_name.index' }
    assert_equal 'passed', check[:status]
  end

  test 'fails when gene feature_name does not match expected gene_name or index' do
    lookup = LookupStub.new(
      remote_available: true,
      remote_organism: Struct.new(:id).new(1),
      gene_statuses: {},
      genes_by_reference_index: {
        ['NCBITaxon:9606', 'ENSG00000141510'] => Struct.new(:name).new('TP53')
      }
    )
    result = Scfair::VarCrossFieldValidator.new(
      field_values: {
        'var/feature_biotype#series' => %w[gene],
        'var/feature_reference#series' => ['NCBITaxon:9606'],
        'var/feature_name#series' => %w[BRCA1],
        'var/_index#series' => %w[ENSG00000141510]
      },
      format: 'h5ad',
      lookup: lookup
    ).call

    error = result[:errors].find { |entry| entry[:field] == 'var.cross_field.feature_name.index' }
    assert_match(/1 of 1 feature failed/, error[:message])
    assert_match(/TP53/, error[:message])
  end

  test 'fails when spike-in feature_name does not match var index' do
    lookup = LookupStub.new(remote_available: false, remote_organism: nil, gene_statuses: {})
    result = Scfair::VarCrossFieldValidator.new(
      field_values: {
        'var/feature_biotype#series' => %w[spike-in],
        'var/feature_reference#series' => ['NCBITaxon:32630'],
        'var/feature_name#series' => %w[ERCC-00003],
        'var/_index#series' => %w[ERCC-00003]
      },
      format: 'h5ad',
      lookup: lookup
    ).call

    error = result[:errors].find { |entry| entry[:field] == 'var.cross_field.feature_name.index' }
    assert_match(/1 of 1 feature failed/, error[:message])
  end

  test 'fails when ensembl_release is missing' do
    lookup = LookupStub.new(
      remote_available: true,
      remote_organism: Struct.new(:id).new(1),
      gene_statuses: { 'ENSG00000141510' => :ok }
    )
    result = Scfair::VarCrossFieldValidator.new(
      field_values: {
        'uns/organism_ontology_term_id' => ['NCBITaxon:9606'],
        'var/_index#series' => %w[ENSG00000141510]
      },
      format: 'h5ad',
      lookup: lookup
    ).call

    index_check = result[:valid_checks].find { |entry| entry[:field] == 'var.cross_field.index.release' }
    assert_equal 'failed', index_check[:status]
    assert_match(/ensembl_release is required/, index_check[:message])
    refute result[:valid_checks].any? { |entry| entry[:field] == 'var.cross_field.feature_name.release' }
  end

  test 'validates var index against ensembl release' do
    lookup = LookupStub.new(
      remote_available: true,
      remote_organism: Struct.new(:id).new(1),
      gene_statuses: { 'ENSG00000141510' => :ok }
    )
    result = Scfair::VarCrossFieldValidator.new(
      field_values: {
        'uns/organism_ontology_term_id' => ['NCBITaxon:9606'],
        'uns/ensembl_release' => ['114'],
        'var/_index#series' => %w[ENSG00000141510]
      },
      format: 'h5ad',
      lookup: lookup
    ).call

    check = result[:valid_checks].find { |entry| entry[:field] == 'var.cross_field.index.release' }
    assert_equal 'passed', check[:status]
  end
end
