# frozen_string_literal: true

module AsapData
  # Resolve obsolete GO identifiers to their ontology successors using
  # go_replacements.json (built from go.obo by compute_go_lineage).
  #
  # Prefers replaced_by; falls back to the first consider entry when present.
  module GoTermReplacement
    module_function

    def replacements_path
      candidates = [
        ENV["GO_REPLACEMENTS_PATH"],
        ENV["GO_JSON_PATH"].present? ? File.join(File.dirname(ENV["GO_JSON_PATH"]), "go_replacements.json") : nil,
        File.join(asap_data_dir.to_s, "go", "go_replacements.json"),
        ENV["PROD_DATA_DIR"].present? ? File.join(ENV["PROD_DATA_DIR"], "go", "go_replacements.json") : nil,
        "/data/asap/go/go_replacements.json",
        "/mnt/asap_data/go/go_replacements.json"
      ].compact
      candidates.find { |p| File.exist?(p) }
    end

    def asap_data_dir
      if defined?(APP_CONFIG) && APP_CONFIG.respond_to?(:[]) && APP_CONFIG[:data_dir]
        APP_CONFIG[:data_dir]
      elsif ENV["DATA_DIR"].present?
        ENV["DATA_DIR"]
      else
        "/data/asap"
      end
    end

    def mapping
      @mapping ||= begin
        path = replacements_path
        path ? JSON.parse(File.read(path)) : {}
      end
    end

    def reset!
      @mapping = nil
    end

    # Returns replacement GO id or nil.
    def resolve(identifier)
      id = identifier.to_s.strip
      return nil if id.blank?

      entry = mapping[id]
      return nil unless entry.is_a?(Hash)

      replaced = Array(entry["replaced_by"]).map(&:to_s).reject(&:blank?)
      return replaced.first if replaced.any?

      consider = Array(entry["consider"]).map(&:to_s).reject(&:blank?)
      consider.first
    end

    def obsolete_entry(identifier)
      mapping[identifier.to_s.strip]
    end

    def chain_resolve(identifier, max_hops: 5)
      current = identifier.to_s.strip
      from = nil
      hops = 0
      while hops < max_hops
        nxt = resolve(current)
        break if nxt.blank? || nxt == current

        from ||= identifier.to_s.strip
        current = nxt
        hops += 1
      end
      { identifier: current, redirected_from: from }
    end
  end
end
