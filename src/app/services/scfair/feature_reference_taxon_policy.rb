# frozen_string_literal: true

module Scfair
  # feature_reference allowance for var metadata: Metazoa, Vertebrata (Ensembl), and Ensembl COVID-19.
  class FeatureReferenceTaxonPolicy
    def self.allowed?(reference, biotype:)
      new.allowed?(reference, biotype:)
    end

    def self.allowed_gene_reference?(reference)
      new.allowed_gene_reference?(reference)
    end

    def initialize(lineage_resolver: NcbiTaxonomyLineageResolver.new, remote_lookup: EnsemblReferenceLookup.new)
      @lineage_resolver = lineage_resolver
      @remote_lookup = remote_lookup
      @config = Rules.feature_reference_policy
    end

    def allowed?(reference, biotype:)
      ref = reference.to_s
      case biotype.to_s
      when 'spike-in'
        ref == spike_in_taxon
      when 'gene'
        allowed_gene_reference?(ref)
      else
        allowed_gene_reference?(ref) || ref == spike_in_taxon
      end
    end

    def allowed_gene_reference?(reference)
      tax_id = extract_tax_id(reference)
      return false unless tax_id

      return true if tax_id == covid_tax_id
      return true if lineage_allowed?(tax_id)
      return true if remote_ensembl_organism?(tax_id)

      false
    end

    def rejection_message(reference, biotype:)
      ref = reference.to_s
      case biotype.to_s
      when 'spike-in'
        return nil if ref == spike_in_taxon

        "#{ref}: spike-in feature_reference must be #{spike_in_taxon}"
      when 'gene'
        return nil if allowed_gene_reference?(ref)

        "#{ref}: not an allowed feature_reference for feature_biotype \"gene\" (#{Rules.feature_reference_policy_requirement_text})"
      else
        return nil if allowed?(ref, biotype:)

        "#{ref}: not an allowed feature_reference for feature_biotype #{biotype.inspect}"
      end
    end

    def lineage_allowed?(tax_id)
      lineage_root_tax_ids.any? { |root_tax_id| @lineage_resolver.descendant_of?(tax_id, root_tax_id) }
    end

    def remote_ensembl_organism?(tax_id)
      return false unless @remote_lookup.remote_available?

      organism = @remote_lookup.remote_organism_for_tax_id(tax_id)
      return false unless organism

      subdomain = @remote_lookup.ensembl_subdomain_for_organism(organism).to_s
      %w[vertebrates metazoa viruses].include?(subdomain)
    rescue StandardError
      false
    end

    private

    def spike_in_taxon
      @config[:spike_in_taxon]
    end

    def covid_tax_id
      @config[:covid_tax_id]
    end

    def lineage_root_tax_ids
      @config[:lineage_root_tax_ids]
    end

    def extract_tax_id(reference)
      match = reference.to_s.match(/\ANCBITaxon:(\d+)\z/)
      return nil unless match

      match[1].to_i
    end
  end

  # Walks parent_tax_id in ncbi_taxonomy_nodes when available.
  class NcbiTaxonomyLineageResolver
    def descendant_of?(tax_id, ancestor_tax_id)
      tax_id = tax_id.to_i
      ancestor_tax_id = ancestor_tax_id.to_i
      return false unless tax_id.positive? && ancestor_tax_id.positive?
      return true if tax_id == ancestor_tax_id
      return false unless taxonomy_available?

      seen = Set.new
      current = tax_id
      while current.positive?
        return true if current == ancestor_tax_id
        break if seen.include?(current)

        seen << current
        node = NcbiTaxonomyNode.find_by(tax_id: current)
        return false unless node

        parent = node.parent_tax_id
        break if parent.nil? || parent == current

        current = parent.to_i
      end

      false
    end

    def taxonomy_available?
      return @taxonomy_available unless @taxonomy_available.nil?

      @taxonomy_available = defined?(NcbiTaxonomyNode) && NcbiTaxonomyNode.table_exists?
    rescue StandardError
      @taxonomy_available = false
    end
  end
end
