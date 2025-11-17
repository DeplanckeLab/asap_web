module ProjectsHelper
  def formatted_organism_name(project)
    return 'Unknown organism' unless project

    organism = project.organism
    short_name = organism&.short_name.to_s.strip
    return short_name if short_name.present?

    full_name = project.organism_display.to_s.strip
    return 'Unknown organism' if full_name.blank?

    scientific_only = full_name.split('(').first.to_s.strip
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
