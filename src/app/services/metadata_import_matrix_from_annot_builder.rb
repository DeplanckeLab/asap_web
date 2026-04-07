# frozen_string_literal: true

# Builds matrix-style TSV {raw_content} for {MetadataImportPrepareStaging} from a source {Annot}
# (same shape as user paste / file matrix import: header row + id/value rows).
class MetadataImportMatrixFromAnnotBuilder
  COL_ID_PATHS = ["/col_attrs/_StableID", "/col_attrs/CellID"].freeze
  ROW_ID_PATHS = ["/row_attrs/_StableID", "/row_attrs/Accession", "/row_attrs/Gene"].freeze

  class << self
    def call(annot:)
      new(annot: annot).call
    end
  end

  def initialize(annot:)
    @annot = annot
  end

  def call
    name = @annot.name.to_s
    unless name.start_with?("/col_attrs/") || name.start_with?("/row_attrs/")
      return error("Only column or row metadata paths can be imported from another project.")
    end

    if @annot.dim.to_i == 3
      return error("This metadata shape is not supported for cross-project import.")
    end

    project = @annot.project
    user_data_dir = ENV.fetch("USER_DATA_DIR")
    loom_path = Pathname.new(user_data_dir) + project.user_id.to_s + project.key + @annot.filepath.to_s
    unless File.exist?(loom_path)
      return error("Loom file for the source metadata was not found on the server.")
    end

    metadata_type_id = name.start_with?("/col_attrs/") ? "1" : "2"
    id_paths = metadata_type_id == "1" ? COL_ID_PATHS : ROW_ID_PATHS
    identifiers = first_non_empty_vector(loom_path.to_s, id_paths)
    unless identifiers.is_a?(Array) && identifiers.any?
      return error("Could not read stable identifiers from the source loom file.")
    end

    values = H5DataService.get_metadata_vector(loom_path.to_s, name)
    unless values.is_a?(Array)
      return error("Could not read metadata values from the source loom file.")
    end

    if values.first.is_a?(Array)
      return error("This metadata cannot be imported as a single column from another project.")
    end

    if values.length != identifiers.length
      return error(
        "Identifier and value counts do not match (#{identifiers.length} vs #{values.length})."
      )
    end

    base = name.sub(%r{\A/col_attrs/}, "").sub(%r{\A/row_attrs/}, "").split("/").last.to_s
    if base.blank?
      return error("Could not determine metadata column name from the source path.")
    end

    id_header = metadata_type_id == "1" ? "Cell names" : "Gene symbols/EnsemblIDs"
    lines = []
    lines << "#{id_header}\t#{base}"

    identifiers.each_with_index do |sid, idx|
      next if sid.nil?

      sid_s = sid.to_s.strip
      next if sid_s.empty?

      lines << "#{sid_s}\t#{format_cell_value(values[idx])}"
    end

    if lines.size < 2
      return error("No data rows could be built for import.")
    end

    { ok: true, raw_content: lines.join("\n"), metadata_type_id: metadata_type_id }
  end

  private

  def error(message)
    { ok: false, error: message, status: :unprocessable_entity }
  end

  def first_non_empty_vector(loom_path, paths)
    paths.each do |p|
      v = H5DataService.get_metadata_vector(loom_path, p)
      return v if v.is_a?(Array) && v.any?
    end
    nil
  end

  def format_cell_value(v)
    return "" if v.nil?

    s = v.is_a?(Float) && !v.finite? ? "" : v.to_s
    s.gsub(/\t/, " ").gsub(/\r|\n/, " ")
  end
end
