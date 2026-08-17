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

  # Generate a label for a loom file in the format: <step label> #<run_number> (<std_method label>)
  # If multiple_runs == false, display only the std_method label (fallback to name)
  # @param filepath [String] The filepath of the loom file
  # @return [String] The formatted label
  def loom_file_label(filepath)
    return filepath unless defined?(@filepath_info) && @filepath_info && @filepath_info[filepath]
    return filepath unless defined?(@loom_file_runs) && @loom_file_runs
    
    run_id = @filepath_info[filepath][:run_id]
    return filepath unless run_id
    
    run = @loom_file_runs[run_id]
    return filepath unless run
    
    std_method_label = if run.std_method
      run.std_method.label.presence || run.std_method.name.presence || ''
    else
      ''
    end
    
    # Check if step has multiple_runs == false
    if run.step && run.step.multiple_runs == false
      return std_method_label.present? ? std_method_label : filepath
    end
    
    # Get step label (prefer label, fallback to name)
    step_label = run.step ? (run.step.label.presence || run.step.name.presence || 'Unknown') : 'Unknown'
    
    # Get run number (prefer num, fallback to id)
    run_number = run.num || run.id
    
    # Build the full label
    parts = [step_label]
    parts << "##{run_number}"
    parts << "(#{std_method_label})" if std_method_label.present? && std_method_label != 'Unknown'
    
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
            data: {
              turbo: false,
              controller: "reset-parsing",
              action: "click->reset-parsing#visit",
              reset_parsing_link: true
            } do
      safe_join([
        tag.i(class: 'fas fa-redo sm:mr-1'),
        tag.span(' Reset', class: 'hidden sm:inline')
      ])
    end
  end

  def organism_assembly_status_tag(assembly_status)
    return '' if assembly_status.blank?

    status = assembly_status.with_indifferent_access
    target_release = status[:release]
    assembly_release = status[:assembly_release]
    name = status[:name].to_s.strip.presence
    present = ActiveModel::Type::Boolean.new.cast(status[:present])

    if name
      display_release = present ? target_release : assembly_release
      label = display_release.present? ? "#{name} (release #{display_release})" : name
      if present
        title = "Assembly #{name} available for Ensembl release #{target_release}"
        css = 'inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium bg-green-100 text-green-800 dark:bg-green-900/40 dark:text-green-300 border border-green-200 dark:border-green-800 ml-auto cursor-help flex-shrink-0 max-w-[55%] truncate'
      else
        title = "Assembly #{name} available up to Ensembl release #{assembly_release}; this assembly doesn't exist in release #{target_release}."
        css = 'inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium bg-amber-100 text-amber-800 dark:bg-amber-900/40 dark:text-amber-300 border border-amber-200 dark:border-amber-800 ml-auto cursor-help flex-shrink-0 max-w-[55%] truncate'
      end
    else
      label = 'no assembly'
      title = 'No assembly available'
      css = 'inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium bg-amber-100 text-amber-800 dark:bg-amber-900/40 dark:text-amber-300 border border-amber-200 dark:border-amber-800 ml-auto cursor-help flex-shrink-0 max-w-[55%] truncate'
    end

    content_tag(:span, label, class: css, title: title)
  end

  def sim_step_options_for_project(project)
    asap_docker_image = Basic.get_asap_docker(project.version)
    return [] unless asap_docker_image

    Step.where(docker_image_id: asap_docker_image.id, version_id: project.version_id)
        .order(:rank)
        .map { |s| [s.label.presence || s.name.humanize, s.id] }
  end

  def annot_storage_type_label(annot, project = nil)
    annot.storage_type_label(project)
  end

  def annot_imported_badge
    content_tag(:span, 'Imported',
                class: 'inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-green-50 text-green-700 border border-green-200',
                title: 'Present in the loom file before or outside the producing analysis run.')
  end

  def annot_asap_pipeline_badge
    content_tag(:span, 'ASAP pipeline',
                class: 'inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-gray-100 text-gray-700 border border-gray-200',
                title: 'Registered from an analysis run in this project.')
  end

  def annot_global_badge
    content_tag(:span, 'Global',
                class: 'inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-gray-100 text-gray-700 border border-gray-200')
  end

  def annot_data_type_badge(annot)
    return '' unless annot&.data_type

    content_tag(:span, annot.data_type.name,
                class: 'inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-gray-100 text-gray-700 border border-gray-200')
  end

  def annot_matrix_type_badge(annot, project = nil)
    label = annot_storage_type_label(annot, project)
    return '' if label.blank?

    css = if annot.integer_storage?
            'bg-amber-50 text-amber-800 border-amber-200'
          elsif annot.float_storage?
            'bg-teal-50 text-teal-800 border-teal-200'
          else
            'bg-gray-100 text-gray-700 border-gray-200'
          end
    content_tag(:span, label, class: "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium border #{css}")
  end

  def annot_data_transformation_badge(annot)
    return '' unless annot.expression_matrix?
    return '' unless annot.data_transformation.present?

    label = annot.data_transformation_label
    return '' if label.blank?

    content_tag(:span, label,
                class: 'inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-slate-100 text-slate-700 border border-slate-200',
                title: annot.data_transformation.description.presence)
  end

  # scFAIR check after key / public id / optional origin badges on the search list.
  # Green when single-cell and latest validation passed; light grey when single-cell
  # but not compliant / not yet validated; nothing for non-single-cell projects.
  # latest_passed_by_project_id must be the batch map from the index action.
  def project_scfair_compliance_list_icon(project, latest_passed_by_project_id)
    return unless project&.single_cell?

    passed = latest_passed_by_project_id[project.id]

    if passed == true
      content_tag(
        :span,
        content_tag(:i, '', class: 'fas fa-check text-green-600 text-xs'),
        class: 'inline-flex items-center shrink-0',
        title: 'scFAIR compliant'
      )
    else
      title = if passed == false
                'scFAIR not compliant'
              else
                'scFAIR not yet validated'
              end
      content_tag(
        :span,
        content_tag(:i, '', class: 'fas fa-check text-gray-300 text-xs'),
        class: 'inline-flex items-center shrink-0',
        title: title
      )
    end
  end

  # Color from ontology_term_types (DB color / explore_color), with EXPLORE_STYLES fallback.
  # Accepts OntologyTermType#name (e.g. "technology") or field_group_id (e.g. "organism").
  def ontology_term_type_color(name_or_field_group)
    key = name_or_field_group.to_s
    ontology_term_type_color_cache[key] ||= begin
      ott = OntologyTermType.find_by(name: key) || OntologyTermType.find_by(field_group_id: key)
      style_key = ott&.field_group_id.presence || ott&.name.presence || key
      ott&.explore_color || OntologyTermType.explore_style_for(style_key)[:color]
    end
  end

  # Colored badges matching scFAIR summary metadata chips (color + 22 alpha background).
  # When limit is set and there are more terms, shows the first N plus a "+X more" button
  # that opens the search-terms-modal (same pattern as summary scFAIR metadata cards).
  # +labels+ may be strings or hashes with :label, :identifier, :url (ontology terms).
  def ontology_term_type_badges(labels, color, unknown_label: 'Unknown', limit: nil, modal_label: nil)
    entries = Array(labels).filter_map { |item| normalize_badge_term_entry(item) }
    entries = [{ label: unknown_label, identifier: nil, url: nil }] if entries.empty?
    hex = color.to_s.presence || '#64748B'
    visible = limit.present? ? entries.first(limit) : entries
    remaining = limit.present? ? [entries.size - visible.size, 0].max : 0

    content_tag(:span, class: 'flex flex-wrap gap-1') do
      parts = visible.map do |entry|
        content_tag(
          :span,
          entry[:label],
          class: 'inline-flex items-center px-2 py-0.5 rounded text-xs font-medium',
          style: "background-color: #{hex}22; color: #{hex};"
        )
      end

      if remaining.positive?
        parts << content_tag(
          :button,
          "+#{remaining} more",
          type: 'button',
          class: 'inline-flex items-center px-2 py-0.5 rounded text-xs font-medium hover:opacity-80 cursor-pointer',
          style: "background-color: #{hex}22; color: #{hex};",
          data: {
            action: 'click->search-terms-modal#open:prevent:stop:capture',
            search_terms_modal_trigger: true,
            card_label: modal_label.presence || 'Terms',
            card_color: hex,
            card_terms: entries.to_json
          },
          aria: { label: "Show all #{entries.size} #{modal_label.present? ? modal_label.downcase.pluralize : 'terms'}" }
        )
      end

      safe_join(parts)
    end
  end

  def search_project_organism_badges(project)
    labels = project&.organism&.name.present? ? [project.organism.name] : []
    ontology_term_type_badges(labels, ontology_term_type_color('organism'))
  end

  def search_project_technology_badges(project)
    entries = project ? project.compliance_term_entries_for('technology', ontology_by_tag: ontology_by_tag_index_cache) : []
    ontology_term_type_badges(
      entries,
      ontology_term_type_color('technology'),
      limit: 2,
      modal_label: 'Technology'
    )
  end

  private

  def ontology_term_type_color_cache
    @ontology_term_type_color_cache ||= {}
  end

  def ontology_by_tag_index_cache
    @ontology_by_tag_index_cache ||= AsapData::OntologyIdentifierUrl.ontology_by_tag_index
  end

  def normalize_badge_term_entry(item)
    if item.is_a?(Hash)
      label = (item[:label] || item['label']).to_s.strip
      identifier = (item[:identifier] || item['identifier']).to_s.strip
      url = (item[:url] || item['url']).to_s.strip
      return nil if label.blank? && identifier.blank?

      {
        label: label.presence || identifier,
        identifier: identifier.presence,
        url: url.presence
      }
    else
      text = item.to_s.strip
      return nil if text.blank?

      { label: text, identifier: nil, url: nil }
    end
  end
end
