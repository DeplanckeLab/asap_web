# frozen_string_literal: true

require "set"

module AsapData
  # Builds the same maps as reading /row_attrs from the loom via ASAP.jar, using
  # parsing/autocomplete_genes.json produced by get_autocomplete_genes (lines are
  # "Gene Accession {stable_id}").
  module DatasetStableLookup
    SEARCH_LINE_RE = /\A(.+) ([^ ]+) \{([^}]*)\}\z/.freeze

    module_function

    # @return [Hash, nil] keys :by_accession, :by_symbol, :stable_ids or nil if unusable
    def from_autocomplete_json_file(path)
      path = path.to_s
      return nil if path.empty? || !File.file?(path)

      payload = JSON.parse(File.read(path))
      build_from_autocomplete_payload(payload)
    rescue JSON::ParserError, Errno::ENOENT, Errno::EACCES, TypeError
      nil
    end

    def build_from_autocomplete_payload(payload)
      search = payload["search"] || payload[:search]
      return nil unless search.is_a?(Array) && search.any?

      by_accession = {}
      by_symbol = {}
      stable_ids = Set.new

      search.each do |line|
        line = line.to_s
        m = line.match(SEARCH_LINE_RE)
        next unless m

        gene = m[1].to_s.strip
        accession = m[2].to_s.strip.downcase
        stable_id = m[3].to_s.strip
        next if stable_id.empty?

        stable_ids.add(stable_id)
        by_accession[accession] ||= stable_id unless accession.empty?
        symbol_key = gene.downcase
        by_symbol[symbol_key] ||= stable_id unless symbol_key.empty?
      end

      return nil if stable_ids.empty?

      { by_accession: by_accession, by_symbol: by_symbol, stable_ids: stable_ids }
    end
  end
end
