# frozen_string_literal: true

module Scfair
  # Converts a minimal extract document into the flat field_values hash used by compliance validators.
  class FieldValuesFromExtract
    ARRAY_MARKER = '__array__'
    SERIES_LIMIT = 500
    DISTINCT_LIMIT = 200

    def self.call(extract, format:)
      new(extract, format: format).call
    end

    def initialize(extract, format:)
      @extract = deep_stringify(extract || {})
      @format = format.to_s
    end

    def call
      out = {}
      merge_inventory!(out)
      merge_uns!(out)
      merge_paired_fields!(out)
      merge_obs_columns!(out)
      merge_var!(out)
      merge_obsm!(out)
      merge_col_embeddings!(out)
      merge_extensions!(out)
      out
    end

    private

    def deep_stringify(value)
      case value
      when Hash
        value.each_with_object({}) { |(k, v), h| h[k.to_s] = deep_stringify(v) }
      when Array
        value.map { |v| deep_stringify(v) }
      else
        value
      end
    end

    def inventory
      @extract['file_inventory'] || {}
    end

    def obs_prefix
      @format == 'h5ad' ? 'obs' : '/col_attrs'
    end

    def var_prefix
      @format == 'h5ad' ? 'var' : '/row_attrs'
    end

    def uns_prefix
      @format == 'h5ad' ? 'uns' : '/attrs'
    end

    def field_path(layer, name)
      Rules.field_path(@format, layer, name)
    end

    def merge_inventory!(out)
      matrix = inventory['matrix'] || {}
      n_obs = matrix['n_obs']
      out['matrix/n_obs'] = [n_obs.to_s] if n_obs.present?

      obs_cols = Array(inventory.dig('obs', 'column_names')).map(&:to_s)
      var_cols = Array(inventory.dig('var', 'column_names')).map(&:to_s)
      uns_keys = Array(inventory.dig('uns', 'top_level_keys')).map(&:to_s)

      out[Rules.metadata_column_list_key('obs')] = obs_cols if obs_cols.any?
      out[Rules.metadata_column_list_key('var')] = var_cols if var_cols.any?
      out[Rules.metadata_column_list_key('uns')] = uns_keys if uns_keys.any?

      structure = inventory['structure'] || {}
      if structure.key?('anndata_mapping_present')
        out['/attrs/anndata_mapping'] = [structure['anndata_mapping_present'].to_s]
      end
    end

    def merge_uns!(out)
      (@extract['uns'] || {}).each do |key, entry|
        next unless entry.is_a?(Hash)

        value = entry['value']
        next if value.nil?

        path = field_path(:uns, key)
        out[path] = [value.to_s]
      end
    end

    def merge_paired_fields!(out)
      merge_paired_layer!('obs', out)
      merge_paired_layer!('uns', out)
    end

    def merge_paired_layer!(layer, out)
      pairs_root = (@extract.dig('paired_fields', layer) || {})
      pairs_root.each do |id_field, block|
        next unless block.is_a?(Hash)

        label_field = block['label_field'].to_s
        pairs = Array(block['pairs'])
        next if pairs.empty?

        layer_sym = layer == 'uns' ? :uns : :obs
        id_path = field_path(layer_sym, id_field)
        pair_tokens = pairs.filter_map do |pair|
          id_val = pair['id'].to_s.strip
          label_val = pair['label'].to_s.strip
          next if id_val.blank? || label_val.blank?

          "#{id_val} || #{label_val}"
        end
        out["#{id_path}#label_pairs"] = pair_tokens.first(DISTINCT_LIMIT) if pair_tokens.any?

        ids = pairs.filter_map { |pair| pair['id'].to_s.strip }.reject(&:blank?).uniq
        out[id_path] = ids.first(DISTINCT_LIMIT) if ids.any?

        if layer == 'obs' && label_field.present?
          labels = pairs.map { |p| p['label'].to_s }.reject(&:blank?).uniq
          out[field_path(:obs, label_field)] = labels.first(DISTINCT_LIMIT) if labels.any?
        end
      end
    end

    def merge_obs_columns!(out)
      columns = @extract.dig('obs', 'columns') || {}
      columns.each do |name, block|
        values = Array(block['distinct_values']).map(&:to_s).reject(&:blank?)
        next if values.empty?

        out[field_path(:obs, name)] = values.first(DISTINCT_LIMIT)
      end
    end

    def merge_var!(out)
      var = @extract['var'] || {}
      index_values = Array(var.dig('index', 'per_feature_values')).map(&:to_s)
      if index_values.any?
        index_path = Rules.var_index_file_path(@format)
        out[index_path] = index_values.uniq.reject(&:blank?).first(DISTINCT_LIMIT)
        # Keep the full ordered index series: uniqueness/format/release checks need all rows.
        out["#{index_path}#series"] = index_values
      end

      (var['columns'] || {}).each do |name, block|
        series = Array(block['per_feature_values']).map(&:to_s)
        next if series.empty?

        path = field_path(:var, name)
        out[path] = series.uniq.reject(&:blank?).first(DISTINCT_LIMIT)
        out["#{path}#series"] = series.first(SERIES_LIMIT)
      end
    end

    def merge_obsm!(out)
      (@extract['obsm'] || {}).each do |key, meta|
        store_array_meta!(out, "obsm/#{key}", meta)
      end
    end

    def merge_col_embeddings!(out)
      (@extract['col_embeddings'] || {}).each do |path, meta|
        store_array_meta!(out, path.to_s, meta)
      end
    end

    def merge_extensions!(out)
      (@extract['extensions'] || {}).each do |name, block|
        prefix = extension_prefix(name)
        next if prefix.blank? || !block.is_a?(Hash)

        (block['scalars'] || {}).each do |rel, scalar|
          next unless scalar.is_a?(Hash)

          path = "#{prefix}/#{rel}"
          out[path] = [scalar['value'].to_s]
        end

        (block['arrays'] || {}).each do |rel, arr|
          store_array_meta!(out, "#{prefix}/#{rel}", arr)
        end
      end
    end

    def extension_prefix(name)
      case @format
      when 'h5ad'
        {
          'spatial' => 'uns/spatial',
          'genetic_perturbations' => 'uns/genetic_perturbations'
        }[name.to_s]
      when 'loom'
        {
          'spatial' => '/attrs/spatial',
          'genetic_perturbations' => '/attrs/genetic_perturbations'
        }[name.to_s]
      end
    end

    def store_array_meta!(out, path, meta)
      return unless meta.is_a?(Hash)

      shape = Array(meta['shape']).map(&:to_i)
      out[path] = [ARRAY_MARKER]
      out["#{path}#shape"] = [shape.join(',')] if shape.any?
      out["#{path}#dtype"] = [meta['dtype'].to_s] if meta['dtype'].present?
      out["#{path}#has_inf"] = [meta['has_inf'].to_s.downcase] if meta.key?('has_inf')
      out["#{path}#has_nan"] = [meta['has_nan'].to_s.downcase] if meta.key?('has_nan')
    end
  end
end
