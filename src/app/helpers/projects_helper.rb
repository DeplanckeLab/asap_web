module ProjectsHelper
  def formatted_organism_name(project)
    return 'Unknown organism' unless project

    organism = project.organism
    return 'Unknown organism' unless organism

    # Use the scientific name from the name field, stripping any common name in parentheses
    full_name = organism.name.to_s.strip
    return 'Unknown organism' if full_name.blank?

    # Extract scientific name by removing anything in parentheses
    scientific_only = full_name.split('(').first.to_s.strip
    return 'Unknown organism' if scientific_only.blank?

    # Format as D. melanogaster if we have at least 2 words
    parts = scientific_only.split(/\s+/)
    scientific_display =
      if parts.length >= 2 && parts.first.present?
        "#{parts.first[0].upcase}. #{parts[1..].join(' ')}"
      else
        scientific_only
      end

    content_tag(:em, scientific_display)
  end

  # Get the row label (e.g., "genes") from project_type, with fallback to "genes"
  # @param project [Project] The project instance
  # @param plural [Boolean] Whether to return plural form (default: true)
  def row_label(project, plural: true)
    label = if project&.project_type
      project.project_type.row_label.presence || 'genes'
    else
      'genes'
    end
    
    if plural
      label.end_with?('s') ? label : "#{label}s"
    else
      label.end_with?('s') ? label.chomp('s') : label
    end
  end

  # Get the column label (e.g., "cells", "samples") from project_type, with fallback to "cells"
  # @param project [Project] The project instance
  # @param plural [Boolean] Whether to return plural form (default: true)
  def col_label(project, plural: true)
    label = if project&.project_type
      project.project_type.col_label.presence || 'cells'
    else
      'cells'
    end
    
    if plural
      label.end_with?('s') ? label : "#{label}s"
    else
      label.end_with?('s') ? label.chomp('s') : label
    end
  end

  # Generate a dimension badge with count and label (with proper pluralization)
  # @param count [Integer] The count value
  # @param label_type [Symbol] Either :row or :col
  # @param project [Project] The project instance
  # @return [String] HTML string for the badge
  def dimension_badge(count, label_type, project)
    return '' unless count.present?
    
    count_int = count.to_i
    is_plural = count_int != 1
    
    label = if label_type == :row
      row_label(project, plural: is_plural)
    else
      col_label(project, plural: is_plural)
    end
    
    badge_class = if label_type == :row
      'inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-blue-50 text-blue-700 border border-blue-200'
    else
      'inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-purple-50 text-purple-700 border border-purple-200'
    end
    
    content_tag(:span, "#{count_int} #{label}", class: badge_class)
  end

  # Column count for the same loom as /matrix: if it matches matrix columns, use
  # col_label (cells); otherwise the value is a table width (e.g. DE fields), not cells.
  def dimension_badge_col_aligned_with_matrix(count, filepath, project)
    return '' unless count.present?

    dims = matrix_dims_for_filepath(project, filepath)
    matrix_cols = dims&.dig(:cols)
    if matrix_cols.present? && count.to_i != matrix_cols.to_i
      table_columns_badge(count)
    else
      dimension_badge(count, :col, project)
    end
  end

  def matrix_dims_for_filepath(project, filepath)
    return nil if project.blank? || filepath.blank?

    @_matrix_dims_for_filepath ||= {}
    key = [project.id, filepath.to_s]
    return @_matrix_dims_for_filepath[key] if @_matrix_dims_for_filepath.key?(key)

    m = Annot.where(project_id: project.id, filepath: filepath, name: '/matrix').first
    @_matrix_dims_for_filepath[key] =
      if m
        { rows: m.nber_rows, cols: m.nber_cols }
      end
  end

  def table_columns_badge(count)
    count_int = count.to_i
    label = (count_int == 1) ? 'column' : 'columns'
    # Same neutral styling as component_dimension_badge: not the cell axis.
    badge_class = 'inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-gray-100 text-gray-700 border border-gray-200'
    content_tag(:span, "#{count_int} #{label}", class: badge_class)
  end

  # Generate a neutral badge for the component dimension of a multi-component
  # metadata annotation (e.g. the 50 PCs of /col_attrs/X_pca or the 2 axes of
  # /col_attrs/X_umap). This is the per-entry vector length and is NOT a
  # gene/cell dimension, so it must not be labeled via row_label/col_label.
  # @param count [Integer] The number of components
  # @return [String] HTML string for the badge, or '' if count is nil/<= 1
  def component_dimension_badge(count)
    return '' unless count.present?
    count_int = count.to_i
    return '' if count_int <= 1

    label = (count_int == 1) ? 'component' : 'components'
    badge_class = 'inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-gray-100 text-gray-700 border border-gray-200'
    content_tag(:span, "#{count_int} #{label}", class: badge_class)
  end

  # Badge showing the number of distinct categories of a categorical annotation.
  # Returns '' for non-categorical annotations or when categories_json is
  # missing/unparseable. The count is derived from the persisted
  # categories_json hash (category => count), so no loom I/O is performed.
  # @param annot [Annot]
  # @return [String] HTML string for the badge, or '' if not applicable
  def categorical_categories_badge(annot)
    return '' unless annot&.data_type_id == 3
    return '' if annot.categories_json.blank?

    parsed = JSON.parse(annot.categories_json)
    return '' unless parsed.is_a?(Hash)

    count_int = parsed.size
    label = (count_int == 1) ? 'category' : 'categories'
    badge_class = 'inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-amber-50 text-amber-700 border border-amber-200'
    content_tag(:span, "#{count_int} #{label}", class: badge_class)
  rescue JSON::ParserError
    ''
  end

  # Generate a label for a loom file in the format: <step name> <std_method_name> #<run_number>
  # If multiple_runs == false, display only <std_method_name> capitalized
  # @param filepath [String] The filepath of the loom file
  # @return [String] The formatted label
  def loom_file_label(filepath)
    return filepath unless defined?(@filepath_info) && @filepath_info && @filepath_info[filepath]
    return filepath unless defined?(@loom_file_runs) && @loom_file_runs
    
    run_id = @filepath_info[filepath][:run_id]
    return filepath unless run_id
    
    run = @loom_file_runs[run_id]
    return filepath unless run
    
    # Get std_method name
    std_method_name = run.std_method ? (run.std_method.name.presence || '') : ''
    
    # Check if step has multiple_runs == false
    if run.step && run.step.multiple_runs == false
      # Display only capitalized std_method_name
      return std_method_name.present? ? std_method_name.capitalize : filepath
    end
    
    # Get step name (prefer label, fallback to name)
    step_name = run.step ? (run.step.label.presence || run.step.name.presence || 'Unknown') : 'Unknown'
    
    # Get run number (prefer num, fallback to id)
    run_number = run.num || run.id
    
    # Build the full label
    parts = [step_name]
    parts << "##{run_number}"
    parts << "(#{std_method_name})" if std_method_name.present? && std_method_name != 'Unknown'
    
    parts.join(' ')
  end

  # Format an annotation name by removing path prefixes
  # @param annot_name [String] The annotation name (e.g., "/col_attrs/CellType")
  # @return [String] The formatted name (e.g., "CellType")
  def format_annot_name(annot_name)
    return 'Unnamed' unless annot_name.present?
    
    formatted = annot_name.to_s
      .gsub(/^\/col_attrs\//, '')
      .gsub(/^\/row_attrs\//, '')
      .gsub(/^\/layers\//, '')
      .gsub(/^\/attrs\//, '')
      .gsub(/^\//, '')
    
    formatted.presence || 'Unnamed'
  end

  # Get the metadata type label for an annotation
  # @param annot [Annot] The annotation object
  # @param project [Project] The project instance
  # @return [String] The metadata type label
  def annot_metadata_type_label(annot, project)
    return 'Expression Matrix' if annot.dim == 3 || annot.name == '/matrix' || annot.name.start_with?('/layers/')
    return "#{col_label(project, plural: false).capitalize} Metadata" if annot.name.start_with?('/col_attrs/')
    return "#{row_label(project, plural: false).capitalize} Metadata" if annot.name.start_with?('/row_attrs/')
    return 'Global Metadata'
  end

  # Generate download URL for a loom file
  # @param filepath [String] The filepath of the loom file
  # @return [String] The download URL or nil if not available
  def loom_file_download_url(filepath)
    return nil unless defined?(@filepath_info) && @filepath_info && @filepath_info[filepath]
    return nil unless defined?(@loom_file_runs) && @loom_file_runs
    
    run_id = @filepath_info[filepath][:run_id]
    return nil unless run_id
    
    run = @loom_file_runs[run_id]
    return nil unless run && run.step
    
    # Extract filename from filepath (last part after "/")
    filename = filepath.split('/').last || 'output.loom'
    
    # Get step name
    step_name = run.step.name
    
    # Build download URL
    get_file_project_path(@project, step: step_name, filename: filename, run_id: run_id)
  end

  # Single chip for output.json "metadata" (e.g. DE --write-metadata), same family as Global metadata badges in run Results.
  def run_output_metadata_summary_html(h_res, project)
    return ''.html_safe unless h_res.is_a?(Hash)

    meta = h_res['metadata']
    return ''.html_safe unless meta.is_a?(Array) && meta.any?

    m = meta.find { |e| e.is_a?(Hash) }
    return ''.html_safe unless m

    raw_name = m['name'].to_s.presence || 'metadata'
    display_name = ERB::Util.html_escape(raw_name.gsub(/\A\/attrs\//, '').gsub(%r{\A/}, ''))

    detail_bits = []
    detail_bits << ERB::Util.html_escape(m['type'].to_s) if m['type'].present?
    if m.key?('nber_rows') && m.key?('nber_cols')
      detail_bits << "#{ERB::Util.html_escape(m['nber_rows'].to_s)} x #{ERB::Util.html_escape(m['nber_cols'].to_s)}"
    elsif m.key?('nber_rows')
      detail_bits << "#{ERB::Util.html_escape(row_label(project, plural: true))} #{ERB::Util.html_escape(m['nber_rows'].to_s)}"
    elsif m.key?('nber_cols')
      detail_bits << "#{ERB::Util.html_escape(col_label(project, plural: true))} #{ERB::Util.html_escape(m['nber_cols'].to_s)}"
    end

    detail_html = if detail_bits.any?
                    %(<span class="text-xs text-gray-500 ml-2">#{detail_bits.join(' · ')}</span>)
                  else
                    ''
                  end

    tooltip_bits = []
    if meta.size > 1
      names = meta.filter_map { |e| e['name'].presence if e.is_a?(Hash) }.map(&:to_s)
      tooltip_bits << "#{meta.size} outputs: #{names.join(', ')}" if names.any?
    end
    col_headers = m['headers'].presence || m['header']
    if col_headers.is_a?(Array) && col_headers.any?
      tooltip_bits << "Columns: #{col_headers.join(', ')}"
    end
    title_attr = if tooltip_bits.any?
                   %{ title="#{ERB::Util.html_escape(tooltip_bits.join(' | '))}"}
                 else
                   ''
                 end

    %(<div class="pt-1"><div class="inline-flex items-center flex-wrap gap-x-1 gap-y-0.5 max-w-full px-3 py-1.5 rounded-md text-sm font-medium bg-white text-gray-700 border border-gray-300"#{title_attr}><span class="font-medium text-gray-800">#{display_name}</span>#{detail_html}</div></div>).html_safe
  end

  def reset_parsing_button(project, extra_class: nil, extra_style: nil)
    base_class = "px-3 py-1.5 bg-orange-600 hover:bg-orange-700 text-white rounded-md font-medium text-sm transition-colors cursor-pointer inline-block border-0"
    css_class = [base_class, extra_class].compact.join(' ')
    link_to reset_parsing_project_path(project),
            class: css_class,
            style: extra_style,
            data: { turbo: false } do
      safe_join([
        tag.i(class: 'fas fa-redo sm:mr-1'),
        tag.span(' Reset', class: 'hidden sm:inline')
      ])
    end
  end
end
