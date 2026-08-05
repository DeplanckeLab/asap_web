# frozen_string_literal: true

# Builds a structured import preview (summary + table) from staged final_content.
class MetadataImportPreviewBuilder
  PREVIEW_ROWS = 25
  SAMPLE_VALUES = 6
  UNMATCHED_SAMPLES = 8

  class << self
    def call(final_content:, duplicates:, metadata_type_id:, input_type_id:, name: nil, project: nil, loom_file: nil)
      new(
        final_content: final_content,
        duplicates: duplicates,
        metadata_type_id: metadata_type_id,
        input_type_id: input_type_id,
        name: name,
        project: project,
        loom_file: loom_file
      ).call
    end
  end

  def initialize(final_content:, duplicates:, metadata_type_id:, input_type_id:, name:, project:, loom_file:)
    @final_content = Array(final_content)
    @duplicates = Array(duplicates)
    @metadata_type_id = metadata_type_id.to_s
    @input_type_id = input_type_id.to_s
    @name = name.to_s.strip.presence
    @project = project
    @loom_file = loom_file.to_s.presence
  end

  def call
    if @metadata_type_id == "4"
      build_global
    elsif @input_type_id == "2"
      build_matrix
    else
      build_list
    end
  end

  private

  def build_global
    lines = @final_content.map { |line| line.to_s }
    preview_lines = lines.first(PREVIEW_ROWS)
    {
      format: "global",
      summary: {
        metadata_count: 1,
        row_count: lines.size,
        duplicate_count: @duplicates.size,
        preview_row_count: preview_lines.size,
        truncated: lines.size > preview_lines.size
      },
      columns: [{ name: "Content", role: "value", inferred_type: "STRING", distinct_count: nil, sample_values: [] }],
      rows: preview_lines.map { |line| [line] }
    }
  end

  def build_list
    rows = []
    metadata_name = @name
    @final_content.each do |line|
      parts = line.to_s.split("\t", 2)
      if parts.size == 2 && %w[cells genes].include?(parts[0].to_s.strip) && rows.empty?
        metadata_name = parts[1].to_s.strip.presence || metadata_name
        next
      end
      identifier = parts[0].to_s
      next if identifier.empty?

      rows << [identifier]
    end

    metadata_name ||= "metadata"
    loom = loom_match_summary(rows.map(&:first))
    {
      format: "list",
      summary: {
        metadata_count: 1,
        row_count: rows.size,
        duplicate_count: @duplicates.size,
        preview_row_count: [rows.size, PREVIEW_ROWS].min,
        truncated: rows.size > PREVIEW_ROWS,
        metadata_names: [metadata_name]
      }.merge(loom),
      columns: [
        { name: identifier_column_label, role: "identifier", inferred_type: "STRING", distinct_count: rows.size, sample_values: [] }
      ],
      rows: rows.first(PREVIEW_ROWS)
    }
  end

  def build_matrix
    return empty_matrix if @final_content.empty?

    header_parts = @final_content.first.to_s.split("\t")
    data_lines = @final_content.drop(1)
    col_count = header_parts.size
    parsed = data_lines.map do |line|
      parts = line.to_s.split("\t")
      parts.fill("", parts.size...col_count)[0...col_count]
    end

    id_header = header_parts[0].to_s.strip.presence || identifier_column_label
    value_headers = header_parts.drop(1).map.with_index { |h, i| h.to_s.strip.presence || "column_#{i + 1}" }
    preview = parsed.first(PREVIEW_ROWS)
    loom = loom_match_summary(parsed.map(&:first))

    columns = [{ name: id_header, role: "identifier", inferred_type: "STRING", distinct_count: parsed.size, sample_values: [] }]
    value_headers.each_with_index do |h, idx|
      values = parsed.map { |r| r[idx + 1].to_s }
      columns << column_stats(h, values, role: "value")
    end

    {
      format: "matrix",
      summary: {
        metadata_count: value_headers.size,
        row_count: parsed.size,
        duplicate_count: @duplicates.size,
        preview_row_count: preview.size,
        truncated: parsed.size > preview.size,
        metadata_names: value_headers
      }.merge(loom),
      columns: columns,
      rows: preview
    }
  end

  def empty_matrix
    {
      format: "matrix",
      summary: {
        metadata_count: 0,
        row_count: 0,
        duplicate_count: @duplicates.size,
        preview_row_count: 0,
        truncated: false,
        metadata_names: []
      },
      columns: [],
      rows: []
    }
  end

  def column_stats(name, values, role:)
    compact = values.map { |v| handle_special_characters(v.to_s) }
    nonempty = compact.reject(&:empty?)
    distinct = nonempty.uniq
    {
      name: name,
      role: role,
      inferred_type: infer_type(nonempty),
      distinct_count: distinct.size,
      sample_values: distinct.first(SAMPLE_VALUES)
    }
  end

  # Mirrors Java model.Metadata#inferType / #isCategorical:
  # DISCRETE if unique count is "categorical", else NUMERIC if all Float-parseable, else STRING.
  def infer_type(values)
    return "STRING" if values.empty?

    categories = {}
    is_numeric = true
    values.each do |raw|
      v = handle_special_characters(raw.to_s)
      if is_numeric
        begin
          Float(v.tr(",", "."))
        rescue ArgumentError, TypeError
          is_numeric = false
        end
      end
      categories[v] = true
    end

    if categorical?(categories.size, values.size)
      "DISCRETE"
    elsif is_numeric
      "NUMERIC"
    else
      "STRING"
    end
  end

  def categorical?(ncat, length)
    return false if ncat > 500
    return true if ncat < 10

    ncat <= (length * 0.10)
  end

  # Subset of tools.Utils.handleSpecialCharacters used before type checks in Java.
  def handle_special_characters(content)
    content.to_s.gsub("\r", "").gsub("\n", "")
  end

  def identifier_column_label
    @metadata_type_id == "2" ? "Gene" : "Cell"
  end

  def loom_match_summary(identifiers)
    result = {
      loom_identifier_count: nil,
      matched_identifier_count: nil,
      unmatched_identifier_count: nil,
      unmatched_samples: []
    }
    return result unless @project && @loom_file
    return result if @metadata_type_id == "4"

    loom_ids = loom_identifier_set
    return result if loom_ids.nil?

    ids = identifiers.map(&:to_s).reject(&:empty?)
    matched = ids.count { |id| loom_ids[id] }
    unmatched = ids.reject { |id| loom_ids[id] }
    {
      loom_identifier_count: loom_ids.size,
      matched_identifier_count: matched,
      unmatched_identifier_count: unmatched.size,
      unmatched_samples: unmatched.first(UNMATCHED_SAMPLES)
    }
  end

  def loom_identifier_set
    user_data_dir = ENV["USER_DATA_DIR"] || Rails.root.join("storage", "user_data").to_s
    project_dir = Pathname.new(user_data_dir) + @project.user_id.to_s + @project.key
    loom_path = project_dir + @loom_file
    return nil unless File.exist?(loom_path)

    path = @metadata_type_id == "2" ? "/row_attrs/Gene" : "/col_attrs/CellID"
    values = H5DataService.get_metadata_vector(loom_path.to_s, path)
    return nil unless values.is_a?(Array)

    values.each_with_object({}) { |v, h| h[v.to_s] = true }
  rescue StandardError => e
    Rails.logger.warn("[MetadataImportPreviewBuilder] loom identifiers unavailable: #{e.class}: #{e.message}")
    nil
  end
end
