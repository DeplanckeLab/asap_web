# frozen_string_literal: true

# Aligns loom metadata vectors to heatmap row/column order for dynamic annotation tracks.
class HeatmapTrackAligner
  LEGEND_MAX_CATEGORIES = 12
  CELL_ID_PATH = "/col_attrs/CellID"
  GENE_NAME_PATH = "/row_attrs/Gene"

  class << self
    def column_values(meta, raw_vector, loom_path)
      col_labels = Array(meta["col_labels"])
      return [] if col_labels.empty?

      if meta["column_mode"].to_s == "group"
        column_cell_indices(meta, col_labels.length).map do |indices|
          aggregate_values(raw_vector, indices)
        end
      else
        cell_id_index = cell_id_index_for(loom_path)
        col_labels.map do |label|
          idx = cell_id_index[label.to_s]
          idx ? normalize_value(raw_vector[idx]) : nil
        end
      end
    end

    def row_values(meta, raw_vector, loom_path)
      row_labels = Array(meta["row_labels"])
      return [] if row_labels.empty?

      gene_index = gene_symbol_index_for(loom_path)
      row_labels.map do |label|
        idx = gene_index[label.to_s]
        idx ? normalize_value(raw_vector[idx]) : nil
      end
    end

    def build_track_payload(annot, values)
      values = Array(values)
      data_type = annot.data_type&.name.to_s.upcase
      track_type = infer_track_type(values, data_type)

      payload = {
        "id" => annot.id,
        "name" => annot.display_name.presence || annot.name,
        "path" => annot.name,
        "type" => track_type,
        "values" => values
      }

      if track_type == "numerical"
        finite = values.filter_map { |v| Float(v) rescue nil }.select { |v| v.finite? }
        payload["min"] = finite.min || 0.0
        payload["max"] = finite.max || 1.0
        payload["show_legend"] = true
      else
        categories = values.map { |v| v.nil? ? nil : v.to_s }.compact.uniq.sort
        payload["categories"] = categories
        payload["show_legend"] = categories.size <= LEGEND_MAX_CATEGORIES
      end

      payload
    end

    private

    def column_cell_indices(meta, expected_len)
      indices = Array(meta["col_cell_indices"])
      return indices if indices.length == expected_len

      Array.new(expected_len) { [] }
    end

    def cell_id_index_for(loom_path)
      cell_ids = H5DataService.get_metadata_vector(loom_path.to_s, CELL_ID_PATH)
      index = {}
      cell_ids.each_with_index do |cid, i|
        key = cid.to_s
        index[key] = i unless index.key?(key)
      end
      index
    end

    def gene_symbol_index_for(loom_path)
      genes = H5DataService.get_metadata_vector(loom_path.to_s, GENE_NAME_PATH)
      index = {}
      genes.each_with_index do |gene, i|
        key = gene.to_s
        index[key] = i unless index.key?(key)
      end
      index
    end

    def aggregate_values(raw_vector, indices)
      vals = Array(indices).filter_map do |i|
        v = raw_vector[i.to_i]
        normalize_value(v)
      end
      return nil if vals.empty?

      numeric = vals.all? { |v| numeric_value?(v) }
      if numeric
        nums = vals.map { |v| v.to_f }
        nums.sum / nums.length
      else
        counts = vals.tally
        counts.max_by { |_, c| c }&.first
      end
    end

    def infer_track_type(values, data_type)
      return "numerical" if data_type == "NUMERIC"

      non_empty = values.reject { |v| blank_value?(v) }
      return "categorical" if non_empty.empty?

      if data_type == "DISCRETE" || data_type == "STRING"
        return "categorical"
      end

      numeric_count = non_empty.count { |v| numeric_value?(v) }
      unique_count = non_empty.map { |v| v.to_s }.uniq.length
      numeric_count == non_empty.length && unique_count > LEGEND_MAX_CATEGORIES ? "numerical" : "categorical"
    end

    def normalize_value(value)
      return nil if blank_value?(value)
      return value.to_f if numeric_value?(value)

      value.to_s
    end

    def blank_value?(value)
      value.nil? || value.to_s.strip.empty? || value.to_s.strip.casecmp("nan").zero?
    end

    def numeric_value?(value)
      return false if blank_value?(value)

      Float(value)
      true
    rescue ArgumentError, TypeError
      false
    end
  end
end
