# frozen_string_literal: true

module Scfair
  # Build Ensembl genome-browser gene links from a url_mask.
  # Example:
  #   https://www.ensembl.org/genome-browser/GCA_002204515.1?focus=gene:AAEL004591
  module EnsemblGeneUrl
    URL_MASK = 'https://www.ensembl.org/genome-browser/#{assembly}?focus=gene:#{id}'.freeze

    module_function

    def build(ensembl_id:, assembly:, url_mask: URL_MASK)
      id = normalize_gene_id(ensembl_id)
      asm = assembly.to_s.strip
      return nil if id.blank? || asm.blank?

      apply_mask(url_mask, id: id, assembly: asm)
    end

    def normalize_gene_id(ensembl_id)
      ensembl_id.to_s.strip.sub(/\.\d+\z/, '')
    end

    def apply_mask(mask, id:, assembly:)
      template = mask.to_s.strip
      return nil if template.blank?

      url = template.dup
      url.gsub!(/\#\{assembly\}/i, ERB::Util.url_encode(assembly.to_s))
      url.gsub!(/\#\{id\}/i, ERB::Util.url_encode(id.to_s))
      url.presence
    end
  end
end
