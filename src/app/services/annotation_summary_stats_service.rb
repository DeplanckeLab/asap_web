# frozen_string_literal: true

require 'set'

# Aggregate per-category summary stats for many genes or metadata vectors.
# Returns compact row hashes only (no full expression / metadata vectors).
class AnnotationSummaryStatsService
  MAX_BATCH_SIZE = 200
  GENE_CHUNK_SIZE = 25

  class Error < StandardError; end
  class ValidationError < Error; end

  def initialize(project:, project_dir:)
    @project = project
    @project_dir = Pathname.new(project_dir)
  end

  def call(
    loom_file:,
    grouping_metadata_id:,
    mode:,
    gene_entries: [],
    metadata_ids: [],
    annot_id: nil,
    layer: nil,
    filters: nil
  )
    loom_path = resolve_loom_path!(loom_file)
    grouping = load_grouping!(grouping_metadata_id, loom_file, loom_path)
    filter_mask = build_filter_mask(filters, loom_file, loom_path, grouping[:n_cells], annot_id: annot_id, layer: layer)

    case mode.to_s
    when 'genes'
      compute_gene_stats(
        loom_path: loom_path,
        loom_file: loom_file,
        grouping: grouping,
        filter_mask: filter_mask,
        gene_entries: gene_entries,
        annot_id: annot_id,
        layer: layer
      )
    when 'continuous'
      compute_continuous_metadata_stats(
        grouping: grouping,
        filter_mask: filter_mask,
        metadata_ids: metadata_ids,
        loom_file: loom_file,
        loom_path: loom_path
      )
    when 'categorical'
      compute_categorical_metadata_stats(
        grouping: grouping,
        filter_mask: filter_mask,
        metadata_ids: metadata_ids,
        loom_file: loom_file,
        loom_path: loom_path
      )
    else
      raise ValidationError, "Unsupported mode: #{mode}"
    end
  end

  private

  def resolve_loom_path!(loom_file)
    relative = loom_file.to_s.strip
    relative = 'parsing/output.loom' if relative.blank?
    path = @project_dir + relative
    raise ValidationError, "Loom file not found: #{relative}" unless File.exist?(path)

    path
  end

  def load_grouping!(grouping_metadata_id, loom_file, loom_path)
    metadata = Annot.find_by(id: grouping_metadata_id, project_id: @project.id)
    raise ValidationError, 'Grouping metadata not found' unless metadata

    type_name = metadata.data_type&.name.to_s
    unless type_name == 'DISCRETE' || type_name == 'STRING'
      raise ValidationError, 'Grouping metadata must be categorical'
    end

    raw = H5DataService.get_metadata_vector(loom_path.to_s, metadata.name)
    raise ValidationError, 'Grouping metadata vector is empty' if raw.blank?

    labels = raw.map { |v| normalize_label(v) }
    n_cells = labels.length
    raise ValidationError, 'Grouping metadata has no cells' if n_cells <= 0

    category_counts = Hash.new(0)
    labels.each { |label| category_counts[label] += 1 }
    sorted_categories = category_counts.keys.sort_by { |cat| [-category_counts[cat], cat.to_s] }

    {
      metadata: metadata,
      labels: labels,
      n_cells: n_cells,
      sorted_categories: sorted_categories,
      name: metadata.display_name.presence || metadata.name
    }
  end

  def compute_gene_stats(loom_path:, loom_file:, grouping:, filter_mask:, gene_entries:, annot_id:, layer:)
    entries = normalize_gene_entries(gene_entries)
    raise ValidationError, 'No genes provided' if entries.empty?
    raise ValidationError, "Too many genes (max #{MAX_BATCH_SIZE})" if entries.size > MAX_BATCH_SIZE

    matrix_name, = resolve_matrix!(loom_file, annot_id: annot_id, layer: layer)
    stable_id_path = resolve_stable_id_path!(loom_file)
    stable_id_vector = H5DataService.get_metadata_vector(loom_path.to_s, stable_id_path)
    raise ValidationError, 'Gene stable ID vector is empty' if stable_id_vector.blank?

    index_by_stable = {}
    stable_id_vector.each_with_index do |value, idx|
      key = value.to_s.strip
      index_by_stable[key] = idx unless index_by_stable.key?(key)
    end

    warnings = []
    resolved = []
    entries.each do |entry|
      sid = entry[:stable_id]
      row_index = index_by_stable[sid]
      if row_index.nil?
        warnings << "Gene not found: #{entry[:label]} (#{sid})"
        next
      end
      resolved << entry.merge(row_index: row_index)
    end
    raise ValidationError, 'No matching genes found in the loom' if resolved.empty?

    category_cell_indexes = build_category_cell_indexes(grouping[:labels], filter_mask)
    rows = []

    resolved.each_slice(GENE_CHUNK_SIZE) do |slice|
      indexes = slice.map { |e| e[:row_index] }
      extracted = H5DataService.extract_row_by_indexes(loom_path.to_s, matrix_name, indexes)
      expression_rows = extracted['rows'] || extracted['values'] || []
      slice.each_with_index do |entry, i|
        values = expression_rows[i]
        unless values.is_a?(Array)
          warnings << "Failed to extract expression for #{entry[:label]}"
          next
        end
        rows.concat(continuous_stat_rows(
          name: entry[:label],
          name_key: 'Gene',
          values: values,
          grouping: grouping,
          category_cell_indexes: category_cell_indexes
        ))
      end
    end

    { rows: rows, warnings: warnings, mode: 'genes' }
  end

  def compute_continuous_metadata_stats(grouping:, filter_mask:, metadata_ids:, loom_file:, loom_path:)
    ids = Array(metadata_ids).map { |id| id.to_i }.reject(&:zero?).uniq
    raise ValidationError, 'No continuous metadata provided' if ids.empty?
    raise ValidationError, "Too many metadata items (max #{MAX_BATCH_SIZE})" if ids.size > MAX_BATCH_SIZE

    category_cell_indexes = build_category_cell_indexes(grouping[:labels], filter_mask)
    rows = []
    warnings = []

    ids.each do |metadata_id|
      metadata = Annot.find_by(id: metadata_id, project_id: @project.id)
      unless metadata
        warnings << "Metadata not found: #{metadata_id}"
        next
      end
      type_name = metadata.data_type&.name.to_s
      unless type_name == 'NUMERIC'
        warnings << "Skipping non-continuous metadata: #{metadata.display_name || metadata_id}"
        next
      end

      path = metadata_loom_path(metadata, loom_file, loom_path)
      raw = H5DataService.get_metadata_vector(path.to_s, metadata.name)
      if raw.blank?
        warnings << "Empty vector for #{metadata.display_name || metadata_id}"
        next
      end
      values = raw.map { |v| to_float_or_nan(v) }
      label = metadata.display_name.presence || metadata.name
      rows.concat(continuous_stat_rows(
        name: label,
        name_key: 'Metadata',
        values: values,
        grouping: grouping,
        category_cell_indexes: category_cell_indexes
      ))
    end

    raise ValidationError, 'No continuous metadata stats could be computed' if rows.empty?

    { rows: rows, warnings: warnings, mode: 'continuous' }
  end

  def compute_categorical_metadata_stats(grouping:, filter_mask:, metadata_ids:, loom_file:, loom_path:)
    ids = Array(metadata_ids).map { |id| id.to_i }.reject(&:zero?).uniq
    raise ValidationError, 'No categorical metadata provided' if ids.empty?
    raise ValidationError, "Too many metadata items (max #{MAX_BATCH_SIZE})" if ids.size > MAX_BATCH_SIZE

    rows = []
    warnings = []

    ids.each do |metadata_id|
      metadata = Annot.find_by(id: metadata_id, project_id: @project.id)
      unless metadata
        warnings << "Metadata not found: #{metadata_id}"
        next
      end
      type_name = metadata.data_type&.name.to_s
      unless type_name == 'DISCRETE' || type_name == 'STRING'
        warnings << "Skipping non-categorical metadata: #{metadata.display_name || metadata_id}"
        next
      end

      path = metadata_loom_path(metadata, loom_file, loom_path)
      raw = H5DataService.get_metadata_vector(path.to_s, metadata.name)
      if raw.blank?
        warnings << "Empty vector for #{metadata.display_name || metadata_id}"
        next
      end

      coloring_labels = raw.map { |v| normalize_label(v) }
      if coloring_labels.length != grouping[:n_cells]
        warnings << "Length mismatch for #{metadata.display_name || metadata_id}"
        next
      end

      meta_name = metadata.display_name.presence || metadata.name
      coloring_counts = Hash.new(0)
      grouping[:n_cells].times do |idx|
        next if filter_mask && filter_mask[idx] == 0

        coloring_counts[coloring_labels[idx]] += 1
      end
      sorted_coloring = coloring_counts.keys.sort_by { |cat| [-coloring_counts[cat], cat.to_s] }

      grouping[:sorted_categories].each do |group_cat|
        cell_indexes = []
        grouping[:labels].each_with_index do |label, idx|
          next if label != group_cat
          next if filter_mask && filter_mask[idx] == 0

          cell_indexes << idx
        end
        group_total = cell_indexes.length
        distribution = Hash.new(0)
        cell_indexes.each { |idx| distribution[coloring_labels[idx]] += 1 }

        sorted_coloring.each do |color_cat|
          count = distribution[color_cat] || 0
          pct = group_total.positive? ? ((count.to_f / group_total) * 100).round(2) : 0.0
          rows << {
            'Metadata' => meta_name,
            'Category' => group_cat,
            'Coloring category' => color_cat,
            'Cell Count' => count,
            '%' => pct
          }
        end
      end
    end

    raise ValidationError, 'No categorical metadata stats could be computed' if rows.empty?

    { rows: rows, warnings: warnings, mode: 'categorical' }
  end

  def continuous_stat_rows(name:, name_key:, values:, grouping:, category_cell_indexes:)
    rows = []
    grouping[:sorted_categories].each do |category|
      indexes = category_cell_indexes[category] || []
      sample = []
      indexes.each do |idx|
        next if idx < 0 || idx >= values.length

        v = values[idx]
        next if v.nil?
        f = v.is_a?(Float) ? v : to_float_or_nan(v)
        next if f.nil? || f.nan?

        sample << f
      end

      if sample.empty?
        rows << {
          name_key => name,
          'Category' => category,
          'Cell Count' => 0,
          'Min' => 0.0,
          'Max' => 0.0,
          'Mean' => 0.0,
          'Median' => 0.0,
          'Q1' => 0.0,
          'Q3' => 0.0,
          'Std Dev' => 0.0
        }
        next
      end

      stats = compute_continuous_stats(sample)
      rows << {
        name_key => name,
        'Category' => category,
        'Cell Count' => sample.length,
        'Min' => stats[:min],
        'Max' => stats[:max],
        'Mean' => stats[:mean],
        'Median' => stats[:median],
        'Q1' => stats[:q1],
        'Q3' => stats[:q3],
        'Std Dev' => stats[:std_dev]
      }
    end
    rows
  end

  # Match client addContinuousSummarySheet: population stddev, floor quantile indexes.
  def compute_continuous_stats(values)
    sorted = values.sort
    n = sorted.length
    mean = values.sum / n.to_f
    variance = values.sum { |v| (v - mean)**2 } / n.to_f
    {
      min: round4(sorted.first),
      max: round4(sorted.last),
      mean: round4(mean),
      median: round4(sorted[n / 2]),
      q1: round4(sorted[(n * 0.25).floor]),
      q3: round4(sorted[(n * 0.75).floor]),
      std_dev: round4(Math.sqrt(variance))
    }
  end

  def build_category_cell_indexes(labels, filter_mask)
    indexes = Hash.new { |h, k| h[k] = [] }
    labels.each_with_index do |label, idx|
      next if filter_mask && filter_mask[idx] == 0

      indexes[label] << idx
    end
    indexes
  end

  def build_filter_mask(filters, loom_file, loom_path, n_cells, annot_id:, layer:)
    return nil if filters.blank?

    categories = normalize_category_filters(filters['categories'] || filters[:categories])
    ranges = normalize_range_filters(filters['ranges'] || filters[:ranges])
    return nil if categories.empty? && ranges.empty?

    mask = Array.new(n_cells, 1)

    categories.each do |metadata_id, selected_labels|
      metadata = Annot.find_by(id: metadata_id, project_id: @project.id)
      next unless metadata

      path = metadata_loom_path(metadata, loom_file, loom_path)
      raw = H5DataService.get_metadata_vector(path.to_s, metadata.name)
      next if raw.blank?

      selected = selected_labels.map { |l| normalize_label(l) }.to_set
      raw.each_with_index do |value, idx|
        break if idx >= n_cells
        next if mask[idx] == 0

        mask[idx] = 0 unless selected.include?(normalize_label(value))
      end
    end

    ranges.each do |key, range|
      min_v = range[:min]
      max_v = range[:max]
      next if min_v.nil? || max_v.nil?

      values =
        if key.to_s.start_with?('gene_')
          stable_id = range[:stable_id].presence || key.to_s.sub(/\Agene_/, '').split('_').first
          next if stable_id.blank?

          load_gene_expression_row(loom_path, loom_file, stable_id, annot_id: annot_id, layer: layer)
        else
          metadata = Annot.find_by(id: key.to_i, project_id: @project.id)
          next unless metadata

          path = metadata_loom_path(metadata, loom_file, loom_path)
          raw = H5DataService.get_metadata_vector(path.to_s, metadata.name)
          next if raw.blank?

          raw.map { |v| to_float_or_nan(v) }
        end
      next if values.blank?

      values.each_with_index do |value, idx|
        break if idx >= n_cells
        next if mask[idx] == 0

        if value.nil? || (value.is_a?(Float) && value.nan?) || value < min_v || value > max_v
          mask[idx] = 0
        end
      end
    end

    mask
  end

  def load_gene_expression_row(loom_path, loom_file, stable_id, annot_id:, layer:)
    matrix_name, = resolve_matrix!(loom_file, annot_id: annot_id, layer: layer)
    stable_id_path = resolve_stable_id_path!(loom_file)
    stable_id_vector = H5DataService.get_metadata_vector(loom_path.to_s, stable_id_path)
    return nil if stable_id_vector.blank?

    row_index = nil
    stable_id_vector.each_with_index do |value, idx|
      if value.to_s.strip == stable_id.to_s.strip
        row_index = idx
        break
      end
    end
    return nil if row_index.nil?

    extracted = H5DataService.extract_row_by_indexes(loom_path.to_s, matrix_name, [row_index])
    rows = extracted['rows'] || extracted['values'] || []
    row = rows[0]
    return nil unless row.is_a?(Array)

    row.map { |v| to_float_or_nan(v) }
  end

  def resolve_matrix!(loom_file, annot_id:, layer:)
    matrix_annot = nil
    if annot_id.present?
      matrix_annot = Annot.find_by(id: annot_id, project_id: @project.id, filepath: loom_file, dim: 3)
    end
    if matrix_annot.nil? && layer.present?
      matrix_annot = Annot.light.where(project_id: @project.id, filepath: loom_file, dim: 3, name: layer).first
    end
    matrix_annot ||= Annot.light.where(project_id: @project.id, filepath: loom_file, dim: 3, name: '/matrix').first
    matrix_name = matrix_annot&.name || '/matrix'
    [matrix_name, matrix_annot&.id]
  end

  def resolve_stable_id_path!(loom_file)
    gene_metadata = Annot.light.where(project_id: @project.id, dim: 2, name: '/row_attrs/_StableID')
                         .where(filepath: loom_file)
                         .first
    gene_metadata&.name.presence || '/row_attrs/_StableID'
  end

  def metadata_loom_path(metadata, default_loom_file, default_loom_path)
    file = metadata.filepath.presence || default_loom_file
    return default_loom_path if file.to_s == default_loom_file.to_s

    path = @project_dir + file
    File.exist?(path) ? path : default_loom_path
  end

  def normalize_gene_entries(gene_entries)
    Array(gene_entries).filter_map do |entry|
      if entry.is_a?(Hash)
        sid = (entry['stable_id'] || entry[:stable_id] || entry['stableId'] || entry[:stableId]).to_s.strip
        next if sid.blank?

        label = (entry['symbol'] || entry[:symbol] || entry['label'] || entry[:label] || sid).to_s.strip
        label = sid if label.blank?
        { stable_id: sid, label: label }
      else
        sid = entry.to_s.strip
        next if sid.blank?

        { stable_id: sid, label: sid }
      end
    end.uniq { |e| e[:stable_id] }
  end

  def normalize_category_filters(raw)
    result = {}
    return result unless raw.is_a?(Hash)

    raw.each do |metadata_id, labels|
      id = metadata_id.to_i
      next if id <= 0

      list = Array(labels).map { |l| normalize_label(l) }.reject(&:blank?)
      result[id] = list if list.any?
    end
    result
  end

  def normalize_range_filters(raw)
    result = {}
    return result unless raw.is_a?(Hash)

    raw.each do |key, range|
      next unless range.is_a?(Hash)

      min_v = range['min'] || range[:min]
      max_v = range['max'] || range[:max]
      next if min_v.nil? || max_v.nil?

      result[key.to_s] = {
        min: min_v.to_f,
        max: max_v.to_f,
        stable_id: (range['stable_id'] || range[:stable_id] || range['stableId'] || range[:stableId]).to_s.strip.presence
      }
    end
    result
  end

  def normalize_label(value)
    actual = value.is_a?(Array) ? value[0] : value
    actual.to_s
  end

  def to_float_or_nan(value)
    actual = value.is_a?(Array) ? value[0] : value
    return Float::NAN if actual.nil?

    Float(actual)
  rescue ArgumentError, TypeError
    Float::NAN
  end

  def round4(value)
    value.to_f.round(4)
  end
end
