module ApplicationHelper
  def display_run(run)
    return "Unknown Run" unless run
    "#{run.step&.label || 'Step'} ##{run.num}"
  end
  
  def duration2(duration)
    return "0 seconds" if duration.nil? || duration <= 0
    
    if duration < 1.minute
      "#{duration.to_i} seconds"
    elsif duration < 1.hour
      "#{(duration / 1.minute).to_i} minutes"
    elsif duration < 1.day
      "#{(duration / 1.hour).to_i} hours"
    else
      "#{(duration / 1.day).to_i} days"
    end
  end
  
  # Note: exportable? is now defined in ProjectAuthorization concern
  # This method checks if project has runs and exportable data
  def has_exportable_data?(project)
    return false unless project
    project.runs.any? && (!project.sandbox? || admin?)
  end
  
  def identifier_link(identifier, identifier_type)
    return identifier unless identifier_type&.url_mask.present?
    
    url = identifier_type.url_mask.gsub(/\#\{id\}/, identifier.to_s)
    link_to identifier, url, target: '_blank', class: 'badge badge-light'
  end
  
  def display_reference(article)
    return "Unknown reference" unless article
    
    authors = article.authors.presence || "Unknown authors"
    title = article.title.presence || "Untitled"
    journal = article.journal&.name.presence || "Unknown journal"
    year = article.year.presence || "Unknown year"
    
    "#{authors}. #{title}. #{journal}. #{year}."
  end

  def category_colors
    @category_colors ||= begin
      colors_file = Rails.root.join('config', 'visualization_colors.yml')
      if File.exist?(colors_file)
        YAML.load_file(colors_file)['category_colors']
      else
        raise "Color configuration file not found at #{colors_file}"
      end
    end
  end

  def create_category_color_map(categories)
    color_map = {}
    categories.each_with_index do |category, index|
      color_map[category] = category_colors[index % category_colors.length]
    end
    color_map
  end

  def display_timestamp(record, key)
    value = record_value(record, key)

    return "—" unless value.present?

    time = value.respond_to?(:to_time) ? value.to_time : Time.zone.parse(value.to_s)
    time.strftime("%Y-%m-%d %H:%M")
  rescue StandardError
    value.to_s
  end

  def record_value(record, key)
    attr = key.to_s
    if record.respond_to?(attr)
      record.public_send(attr)
    elsif record.respond_to?(:[])
      record[attr] || record[attr.to_sym]
    end
  end

  def admin_menu_links
    [
      {
        label: "Cross-references",
        description: "Manage identifier types & external links",
        path: cross_references_admin_home_index_path,
        icon: "fas fa-link"
      },
      { label: "Tools", path: tools_path, icon: "fas fa-wrench" },
      { label: "Tool Types", path: tool_types_path, icon: "fas fa-tags" },
      { label: "Docker Images", path: docker_images_path, icon: "fas fa-cube" },
      { label: "Organisms", path: organisms_path, icon: "fas fa-dna" }
    ]
  end

  def info_menu_links
    [
      {
        label: "Versions",
        description: "Release notes & changelog",
        path: versions_path,
        icon: "fas fa-code-branch"
      },
      {
        label: "Cell ontologies",
        description: "Ontology catalogs mirrored from legacy ASAP",
        path: cell_ontologies_path,
        icon: "fas fa-network-wired"
      },
      {
        label: "Ontology term types",
        description: "Definitions and lineage rules used by ASAP",
        path: ontology_term_types_path,
        icon: "fas fa-diagram-project"
      },
      {
        label: "Cross-references",
        description: "Identifier types and external database links",
        path: cross_references_home_index_path,
        icon: "fas fa-link"
      },
      {
        label: "Tutorials",
        description: "Step-by-step guides for new users",
        path: tutorial_home_index_path,
        icon: "fas fa-chalkboard-teacher"
      },
      {
        label: "File formats",
        description: "Supported upload and export formats",
        path: file_format_home_index_path,
        icon: "fas fa-file-alt"
      },
      {
        label: "FAQ",
        description: "Frequently asked questions about ASAP",
        path: faq_home_index_path,
        icon: "fas fa-question-circle"
      }
    ]
  end

  def display_file_format(f)
    return "" unless f

    color = f.color.presence || 'grey'
    label = f.label.presence || 'no label'
    
    raw "<i class='far fa-file fa-3x'><div style='position:relative;top:-26px;left:6px;width:38px;font-size:10px;font-weight:bold;text-align:center;font-family:Arial, Helvetica, sans-serif;background-color:#{color};color:white;padding:3px;border:2px solid white'>#{label}</div></i>"
  end
end

# Basic utility class for JSON parsing
class Basic
  def self.safe_parse_json(json_string, default = {})
    return default unless json_string.present?
    JSON.parse(json_string) rescue default
  end
end
