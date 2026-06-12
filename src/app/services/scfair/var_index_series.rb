# frozen_string_literal: true

module Scfair
  # Resolves ordered var index identifiers from extracted field values (H5AD or Loom).
  module VarIndexSeries
    SERIES_SUFFIX = '#series'

    module_function

    def resolve(field_values, format)
      values = field_values || {}
      fmt = format.to_s
      paths = candidate_paths(fmt, values)

      paths.each do |path|
        series = series_for_path(values, path)
        next if series.empty?

        return { path: path, values: series }
      end

      nil
    end

    def candidate_paths(format, field_values)
      paths = []
      paths << Rules.var_index_logical_path(format)
      paths << Rules.var_index_file_path(format)
      Rules.var_index_column_keys(format).each do |column|
        path = Rules.field_path(format, :var, column)
        paths << path unless paths.include?(path)
      end

      manifest_key = manifest_var_index_key(field_values)
      if manifest_key.present?
        manifest_path = Rules.field_path(format, :var, manifest_key)
        paths << manifest_path unless paths.include?(manifest_path)
      end

      paths << 'var/_index' unless paths.include?('var/_index')
      paths << 'var/index' unless paths.include?('var/index')
      paths
    end

    def manifest_var_index_key(field_values)
      key = Rules.var_index_manifest_key
      return nil if key.blank?

      path = "/attrs/anndata_mapping##{key}"
      Array(field_values[path] || field_values[path.to_sym]).first.to_s.strip.presence
    end

    def series_for_path(field_values, path)
      series_key = "#{path}#{SERIES_SUFFIX}"
      Array(field_values[series_key] || field_values[series_key.to_sym])
        .map(&:to_s).map(&:strip)
    end
  end
end
