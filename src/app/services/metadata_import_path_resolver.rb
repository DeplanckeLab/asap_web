# frozen_string_literal: true

# Resolves LOOM attribute paths for file-based metadata import (prepare_metadata / do_import_metadata).
# Scope: column and row metadata (metadata_type_id 1 and 2). Global imports (type 4) skip path rules.
class MetadataImportPathResolver
  class << self
    # Returns :global for metadata_type_id 4 (no single /col_attrs or /row_attrs path).
    # Returns [] if paths cannot be determined (caller should report user error).
    # Otherwise returns unique normalized paths under /col_attrs/ or /row_attrs/.
    def candidate_paths(metadata_type_id:, input_type_id:, name:, header_name:, has_header:, raw_content:)
      mt = metadata_type_id.to_s
      return :global if mt == "4"
      return [] unless %w[1 2].include?(mt)

      it = input_type_id.to_s
      raw = raw_content.to_s

      if it == "1"
        logical = header_name.presence || name.to_s.strip
        logical = logical.to_s.strip
        return [] if logical.blank?

        [normalize_loom_path(mt, logical)].compact.uniq
      elsif it == "2"
        return [] unless truthy_header?(has_header)
        return [] if raw.blank?

        first_line = raw.split(/\n/).first.to_s
        parts = first_line.split(/\t/)
        return [] if parts.size < 2

        paths = []
        (1...parts.size).each do |i|
          seg = parts[i].to_s.strip
          next if seg.blank?

          p = normalize_loom_path(mt, seg)
          paths << p if p
        end
        paths.uniq
      else
        []
      end
    end

    def normalize_loom_path(metadata_type_id, raw_name)
      raw = raw_name.to_s.strip
      return nil if raw.blank?

      case metadata_type_id.to_s
      when "1"
        return raw if raw.start_with?("/col_attrs/")
        "/col_attrs/#{raw.delete_prefix('/')}"
      when "2"
        return raw if raw.start_with?("/row_attrs/")
        "/row_attrs/#{raw.delete_prefix('/')}"
      end
    end

    def truthy_header?(has_header)
      has_header.to_s != "0" && has_header != false
    end
  end
end
