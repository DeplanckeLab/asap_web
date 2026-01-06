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
end
