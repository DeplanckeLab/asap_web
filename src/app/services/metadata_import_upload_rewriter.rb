# frozen_string_literal: true

# Rewrites staged import file headers so path remaps can retarget LOOM attribute names.
# Only touches the first line (list or matrix header row).
class MetadataImportUploadRewriter
  class << self
    def apply_path_map!(filepath:, metadata_type_id:, input_type_id:, path_map:)
      return false if path_map.blank? || !File.exist?(filepath)

      mt = metadata_type_id.to_s
      it = input_type_id.to_s
      if it == "1"
        rewrite_list!(filepath, mt, path_map)
      elsif it == "2"
        rewrite_matrix!(filepath, mt, path_map)
      else
        false
      end
    end

    private

    def rewrite_list!(filepath, metadata_type_id, path_map)
      lines = File.read(filepath).split("\n")
      return false if lines.empty?

      m = lines[0].match(/\A(cells|genes)\t(.+)\z/)
      return false unless m

      prefix = m[1]
      raw_seg = m[2].strip
      normalized = MetadataImportPathResolver.normalize_loom_path(metadata_type_id, raw_seg)
      return false unless normalized

      replacement = path_map[normalized]
      return false unless replacement

      lines[0] = "#{prefix}\t#{replacement}"
      File.write(filepath, lines.join("\n"))
      true
    end

    def rewrite_matrix!(filepath, metadata_type_id, path_map)
      lines = File.read(filepath).split("\n")
      return false if lines.empty?

      parts = lines[0].split(/\t/)
      return false if parts.size < 2

      changed = false
      (1...parts.size).each do |i|
        seg = parts[i].to_s.strip
        next if seg.blank?

        normalized = MetadataImportPathResolver.normalize_loom_path(metadata_type_id, seg)
        next unless normalized

        replacement = path_map[normalized]
        next unless replacement

        parts[i] = replacement
        changed = true
      end
      return false unless changed

      lines[0] = parts.join("\t")
      File.write(filepath, lines.join("\n"))
      true
    end
  end
end
