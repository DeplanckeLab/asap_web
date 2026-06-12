# frozen_string_literal: true

module Scfair
  # Resolves organism, assembly, and gene annotation data from the ASAP reference DB.
  class EnsemblReferenceLookup
    SPIKE_IN_TAXON = 'NCBITaxon:32630'

    def initialize(remote_db: nil)
      @remote_db = remote_db.presence || default_remote_db
    end

    def remote_available?
      return @remote_available unless @remote_available.nil?

      @remote_available = begin
        db = @remote_db.to_s
        db.present? && RemoteOrganism.remote_versions.include?(db)
      rescue StandardError
        false
      end
    end

    def remote_organism_for_tax_id(tax_id)
      return nil unless remote_available?

      RemoteOrganism.with_remote(@remote_db) do
        RemoteOrganism.find_by(tax_id: tax_id.to_i)
      end
    rescue StandardError
      nil
    end

    def assemblies_for_tax_id(tax_id)
      organism = remote_organism_for_tax_id(tax_id)
      return [] unless organism

      RemoteAssembly.with_remote(@remote_db) do
        RemoteAssembly.where(organism_id: organism.id).order(:name).to_a
      end
    rescue StandardError
      []
    end

    def assembly_matches_name?(assemblies, reported_name)
      normalized = normalize_assembly_name(reported_name)
      return false if normalized.blank?

      assemblies.any? do |assembly|
        candidate = normalize_assembly_name(assembly.name)
        candidate == normalized ||
          candidate.start_with?(normalized) ||
          normalized.start_with?(candidate)
      end
    end

    def assembly_supports_release?(assembly, release)
      release = release.to_i
      return false unless release.positive?

      first = assembly.first_ensembl_release.to_i
      latest = assembly.latest_ensembl_release.to_i
      return false if first.positive? && release < first
      return false if latest.positive? && release > latest

      true
    end

    def release_supported_by_organism?(tax_id, release)
      assemblies_for_tax_id(tax_id).any? { |assembly| assembly_supports_release?(assembly, release) }
    end

    def matching_assemblies(assemblies, reported_name, release: nil)
      normalized = normalize_assembly_name(reported_name)
      assemblies.select do |assembly|
        candidate = normalize_assembly_name(assembly.name)
        name_match = candidate == normalized ||
                     candidate.start_with?(normalized) ||
                     normalized.start_with?(candidate)
        next false unless name_match
        next true if release.blank?

        assembly_supports_release?(assembly, release)
      end
    end

    def gene_status_at_release(organism_id:, release:, symbol: nil, ensembl_id: nil)
      return :unavailable unless remote_available?

      gene = lookup_gene(organism_id:, symbol:, ensembl_id:)
      return :not_found if gene.nil?

      first = gene.first_ensembl_release.to_i
      return :too_new if first.positive? && release.to_i < first

      latest = gene.latest_ensembl_release.to_i
      return :deprecated if latest.positive? && release.to_i > latest

      :ok
    rescue StandardError
      :unavailable
    end

    def normalize_ensembl_id(value)
      id = value.to_s.strip
      return nil if id.blank?

      id.sub(/\.\d+\z/, '')
    end

    def spike_in_feature_name?(value)
      value.to_s.match?(/ERCC|spike-in control/i)
    end

    def spike_in_feature_name_format_valid?(value)
      value.to_s.match?(/\AERCC-\d+ \(spike-in control\)\z/i)
    end

    def known_gene_reference_taxon?(reference)
      Rules.feature_reference_taxa.key?(reference.to_s) &&
        reference.to_s != SPIKE_IN_TAXON
    end

    def gene_for_reference_and_index(feature_reference, index_id)
      return nil unless remote_available?

      tax_id = extract_tax_id(feature_reference)
      return nil unless tax_id

      organism = remote_organism_for_tax_id(tax_id)
      return nil unless organism

      lookup_gene(organism_id: organism.id, ensembl_id: normalize_ensembl_id(index_id))
    rescue StandardError
      nil
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

    def allowed_feature_reference?(reference, biotype:)
      reference = reference.to_s
      case biotype.to_s
      when 'spike-in'
        reference == SPIKE_IN_TAXON
      when 'gene'
        known_gene_reference_taxon?(reference)
      else
        feature_reference_taxa.key?(reference)
      end
    end

    def feature_reference_taxa
      Rules.feature_reference_taxa
    end

    def extract_tax_id(term_id)
      match = term_id.to_s.match(/\ANCBITaxon:(\d+)\z/)
      return nil unless match

      match[1].to_i
    end

    private

    def default_remote_db
      RemoteOrganism.send(:default_remote_db)
    rescue StandardError
      nil
    end

    def lookup_gene(organism_id:, symbol:, ensembl_id:)
      if ensembl_id.present?
        return RemoteGene.find_by_organism_and_ensembl(organism_id, ensembl_id, version: @remote_db)
      end

      return nil if symbol.blank?

      RemoteGene.find_by_organism_and_symbol(organism_id, symbol, version: @remote_db)
    end

    def normalize_assembly_name(value)
      value.to_s.strip.downcase.gsub(/[^a-z0-9]+/, '')
    end
  end
end
