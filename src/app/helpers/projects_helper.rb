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
end
