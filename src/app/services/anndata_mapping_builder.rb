# frozen_string_literal: true

# Builds a per-loom /attrs/anndata_mapping document from repo defaults + Annot rows
# (DataClass / dim / matrix paths) and optional parse-time input_group provenance.
#
# Defaults: src/config/scfair/anndata_mapping_defaults.json
# Spec: docs/loom-creation-spec-for-h5ad-roundtrip.md
class AnndataMappingBuilder
  DEFAULTS_PATH = Rails.root.join('config/scfair/anndata_mapping_defaults.json').freeze
  ATTR_NAME = 'anndata_mapping'
  LOOM_ATTR_PATH = "/attrs/#{ATTR_NAME}"

  RAW_INPUT_GROUPS = ['/raw/X', '/raw.X'].freeze
  RAW_LAYER_NAMES = %w[raw_X raw.X raw].freeze
  X_LAYER_NAMES = %w[X].freeze
  X_LAYER_PATH = '/layers/X'

  RESERVED_OBS_INDEX_KEYS = %w[CellID cell_id cell_ids barcode barcodes Barcode obs_names index _index].freeze
  RESERVED_VAR_INDEX_KEYS = %w[Accession Name Gene Original_Gene gene gene_name var_names index _index].freeze

  KNOWN_UNS_JSON_KEYS = %w[analysis_pipeline].freeze
  # scFAIR uns HDF5 groups (not JSON). Exporters copy these loom groups into h5ad uns.
  UNS_GROUP_PATHS = {
    'spatial' => '/attrs/spatial'
  }.freeze

  class << self
    def call(project:, loom_filepath:, input_group: nil, existing: nil)
      new(
        project: project,
        loom_filepath: loom_filepath,
        input_group: input_group,
        existing: existing
      ).call
    end

    def load_defaults
      raw = JSON.parse(File.read(DEFAULTS_PATH))
      raw.fetch('defaults')
    end
  end

  def initialize(project:, loom_filepath:, input_group: nil, existing: nil)
    @project = project
    @loom_filepath = loom_filepath.to_s.sub(%r{\A/+}, '').sub(/\.h5ad\z/i, '.loom')
    @explicit_input_group = input_group.presence
    @existing = existing.is_a?(Hash) ? existing : nil
    @input_group = @explicit_input_group || existing_input_group(@existing)
  end

  def call
    defaults = self.class.load_defaults
    annots = loom_annots

    matrix_map = build_matrix_map(annots)
    obsm, varm = build_embedding_maps(annots)
    categoricals = build_categoricals(annots)
    uns_json_keys = build_uns_json_keys(annots)
    uns_groups = build_uns_groups(annots)
    obs_index_key, var_index_key = resolve_index_keys(annots, defaults)

    payload = defaults.merge(
      'x_path' => matrix_map[:x_path],
      'obs_path' => defaults['obs_path'],
      'var_path' => defaults['var_path'],
      'obs_index_key' => obs_index_key,
      'var_index_key' => var_index_key,
      'h5ad_obs_index_key' => defaults['h5ad_obs_index_key'] || '_index',
      'h5ad_var_index_key' => defaults['h5ad_var_index_key'] || '_index',
      'layers' => matrix_map[:layers],
      'obsm' => obsm,
      'varm' => varm,
      'obsp' => {},
      'varp' => {},
      'uns_json_keys' => uns_json_keys,
      'uns_groups' => uns_groups,
      'categoricals' => categoricals
    )

    payload['raw_x_path'] = matrix_map[:raw_x_path] if matrix_map[:raw_x_path].present?
    payload['input_group'] = @input_group if @input_group.present?
    payload['notes'] = build_notes(matrix_map)

    payload
  end

  private

  def existing_input_group(existing)
    return nil unless existing.is_a?(Hash)

    existing['input_group'].presence || existing[:input_group].presence
  end

  def loom_annots
    Annot.where(project_id: @project.id, filepath: @loom_filepath, latest_version: true)
         .includes(:data_type, :original_run)
         .to_a
  end

  def build_matrix_map(annots)
    matrix_annot = annots.find { |a| a.name == '/matrix' && a.dim.to_i == 3 }
    layer_annots = annots.select { |a| a.name.to_s.start_with?('/layers/') && a.dim.to_i == 3 }
    layer_by_name = {}
    layer_annots.each do |a|
      layer_by_name[a.name.to_s.sub(%r{\A/layers/}, '')] = a.name.to_s
    end

    # Prefer matrix roles already written at parse time unless a new input_group is supplied.
    if @explicit_input_group.blank? && @existing.is_a?(Hash) && @existing['x_path'].present?
      return preserve_existing_matrix_map(layer_by_name)
    end

    x_path, raw_x_path = roles_from_input_group(layer_by_name, matrix_annot)
    if x_path.blank?
      x_path, raw_x_path = roles_from_annots(layer_by_name, matrix_annot)
    end

    used = [x_path, raw_x_path].compact
    layers = {}
    layer_by_name.each do |name, path|
      next if used.include?(path)

      layers[name] = path
    end

    { x_path: x_path || '/matrix', raw_x_path: raw_x_path, layers: layers }
  end

  def preserve_existing_matrix_map(layer_by_name)
    x_path = @existing['x_path'].to_s
    raw_x_path = @existing['raw_x_path'].presence
    used = [x_path, raw_x_path].compact
    layers = {}
    layer_by_name.each do |name, path|
      next if used.include?(path)

      layers[name] = path
    end
    # Keep previously declared layer keys that still exist; drop stale ones.
    if @existing['layers'].is_a?(Hash)
      @existing['layers'].each do |name, path|
        layers[name] = path if layer_by_name[name] == path || layer_by_name.value?(path)
      end
    end
    { x_path: x_path, raw_x_path: raw_x_path, layers: layers }
  end

  def roles_from_input_group(layer_by_name, matrix_annot)
    return [nil, nil] if @explicit_input_group.blank?
    return [nil, nil] unless matrix_annot

    if RAW_INPUT_GROUPS.include?(@explicit_input_group)
      raw_x_path = '/matrix'
      x_layer = X_LAYER_NAMES.map { |n| layer_by_name[n] }.compact.first
      x_path = x_layer.presence || '/matrix'
      raw_x_path = nil if x_path == '/matrix'
      [x_path, raw_x_path]
    elsif @explicit_input_group == '/X' || (@explicit_input_group.end_with?('/X') && !RAW_INPUT_GROUPS.include?(@explicit_input_group))
      x_path = '/matrix'
      raw_layer = RAW_LAYER_NAMES.map { |n| layer_by_name[n] }.compact.first
      [x_path, raw_layer]
    else
      # Non-standard sel (assay name, 10x group, etc.): primary is /matrix.
      x_path = '/matrix'
      raw_layer = RAW_LAYER_NAMES.map { |n| layer_by_name[n] }.compact.first
      [x_path, raw_layer]
    end
  end

  def roles_from_annots(layer_by_name, matrix_annot)
    return ['/matrix', nil] unless matrix_annot

    names = matrix_annot.data_class_names
    x_layer = X_LAYER_NAMES.map { |n| layer_by_name[n] }.compact.first
    raw_layer = RAW_LAYER_NAMES.map { |n| layer_by_name[n] }.compact.first

    # Case A: counts in /matrix and normalized X kept as a layer.
    if names.include?('int_matrix') && x_layer.present?
      return [x_layer, '/matrix']
    end

    # Case B: /matrix is analysis X; optional raw in a layer.
    ['/matrix', raw_layer]
  end

  def build_embedding_maps(annots)
    obsm = {}
    varm = {}

    annots.each do |annot|
      name = annot.name.to_s
      key = name.split('/').last
      next if key.blank?

      if name.start_with?('/col_attrs/') && obsm_annot?(annot, key)
        obsm[key] = name
      elsif name.start_with?('/row_attrs/') && varm_annot?(annot, key)
        varm[key] = name
      end
    end

    [obsm, varm]
  end

  def obsm_annot?(annot, key)
    return false if RESERVED_OBS_INDEX_KEYS.include?(key)
    # AnnData obsm must be 2D. ASAP stores that as dim=1 col_attrs with nber_rows > 1
    # (coordinate axes x cells). 1D vectors (nber_rows == 1) belong in obs — including
    # cell selections named like X_tsne.sel_N that inherit an X_ prefix from the parent
    # embedding and must not be declared in anndata_mapping['obsm'].
    return false unless annot.dim.to_i == 1 && annot.nber_rows.to_i > 1

    return true if annot.embedding?
    return true if key == 'spatial' || key.start_with?('X_')
    return true if key.match?(/\A_(umap|tsne|pca|dr)_/i)

    true
  end

  def varm_annot?(annot, key)
    return false if RESERVED_VAR_INDEX_KEYS.include?(key)
    return true if annot.dim.to_i == 2 && annot.nber_cols.to_i > 1

    false
  end

  def build_categoricals(annots)
    out = {}
    annots.each do |annot|
      name = annot.name.to_s
      next unless name.start_with?('/col_attrs/') || name.start_with?('/row_attrs/')

      key = name.split('/').last
      next if key.blank?
      next unless discrete_annot?(annot)

      cats = category_labels_in_list_cat_order(annot)
      next if cats.blank?

      out[key] = { 'categories' => cats, 'ordered' => false }
    end
    out
  end

  # Prefer Annot#list_cat_json order exactly (same order used by UI / DE group indexing).
  # Fall back to categories_json only when list_cat_json is absent.
  def category_labels_in_list_cat_order(annot)
    if annot.list_cat_json.present?
      parsed = Basic.safe_parse_json(annot.list_cat_json, nil)
      case parsed
      when Array
        return parsed.map { |c| c.nil? ? '' : c.to_s }
      when Hash
        # Rare object-shaped list_cat_json: keep Basic's stable key ordering, use keys as labels
        # when values are counts; otherwise use ordered values as labels.
        keys = parsed.keys
        ordered_keys =
          if keys.all? { |k| k.to_s.match?(/\A-?\d+\z/) }
            keys.sort_by { |k| k.to_i }
          elsif keys.all? { |k| k.to_s.match?(/\A-?\d*\.?\d+\z/) }
            keys.sort_by { |k| k.to_f }
          else
            keys
          end
        sample = parsed[ordered_keys.first]
        if sample.is_a?(Numeric)
          return ordered_keys.map(&:to_s)
        end

        return ordered_keys.map { |k| parsed[k].to_s }
      end
    end

    return [] if annot.categories_json.blank?

    cats = Basic.safe_parse_json(annot.categories_json, {})
    return [] unless cats.is_a?(Hash) && cats.any?

    keys = cats.keys
    ordered_keys =
      if keys.all? { |k| k.to_s.match?(/\A-?\d+\z/) }
        keys.sort_by { |k| k.to_i }
      elsif keys.all? { |k| k.to_s.match?(/\A-?\d*\.?\d+\z/) }
        keys.sort_by { |k| k.to_f }
      else
        keys
      end
    ordered_keys.map(&:to_s)
  end

  def discrete_annot?(annot)
    return true if annot.data_type&.name == 'DISCRETE'
    return true if annot.data_class_names.include?('discrete_mdata')

    false
  end

  def build_uns_json_keys(annots)
    keys = KNOWN_UNS_JSON_KEYS.dup
    annots.each do |annot|
      next unless annot.dim.to_i == 4

      name = annot.name.to_s
      next unless name.start_with?('/attrs/')

      key = name.sub(%r{\A/attrs/}, '')
      next if key.blank? || key == ATTR_NAME
      next if uns_group_key_for_attr_path(name)

      keys << key if KNOWN_UNS_JSON_KEYS.include?(key) || key.include?('pipeline')
    end
    keys.uniq
  end

  def build_uns_groups(annots)
    groups = {}
    annots.each do |annot|
      uns_key = uns_group_key_for_attr_path(annot.name.to_s)
      next unless uns_key

      groups[uns_key] = UNS_GROUP_PATHS[uns_key]
    end
    groups
  end

  def uns_group_key_for_attr_path(name)
    UNS_GROUP_PATHS.each do |uns_key, loom_path|
      return uns_key if name == loom_path || name.start_with?("#{loom_path}/")
    end
    nil
  end

  def resolve_index_keys(annots, defaults)
    obs_keys = annots.select { |a| a.name.to_s.start_with?('/col_attrs/') }.map { |a| a.name.to_s.split('/').last }
    var_keys = annots.select { |a| a.name.to_s.start_with?('/row_attrs/') }.map { |a| a.name.to_s.split('/').last }

    obs = RESERVED_OBS_INDEX_KEYS.find { |k| obs_keys.include?(k) } || defaults['obs_index_key']
    var = RESERVED_VAR_INDEX_KEYS.find { |k| var_keys.include?(k) } || defaults['var_index_key']
    [obs, var]
  end

  def build_notes(matrix_map)
    parts = []
    parts << "input_group=#{@input_group}" if @input_group.present?
    parts << "x_path=#{matrix_map[:x_path]}"
    parts << "raw_x_path=#{matrix_map[:raw_x_path]}" if matrix_map[:raw_x_path].present?
    parts << 'built_from=annots+defaults'
    parts.join('; ')
  end
end
