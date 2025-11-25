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
end
