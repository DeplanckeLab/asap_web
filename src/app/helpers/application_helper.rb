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

  # Format duration in seconds to human-readable format (HH:MM:SS or MM:SS)
  def duration(seconds)
    return "0s" if seconds.nil? || seconds <= 0
    
    seconds = seconds.to_i
    hours = seconds / 3600
    minutes = (seconds % 3600) / 60
    secs = seconds % 60
    
    if hours > 0
      sprintf("%d:%02d:%02d", hours, minutes, secs)
    else
      sprintf("%d:%02d", minutes, secs)
    end
  end

  # Format number with thousand delimiters
  def number_with_delimiter(number)
    return "0" if number.nil?
    number.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
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
      { label: "Organisms", path: organisms_path, icon: "fas fa-dna" },
      { label: "Steps", path: steps_path, icon: "fas fa-list-ol" },
      { label: "Methods", path: std_methods_path, icon: "fas fa-cogs" },
      { label: "Run statuses", path: statuses_path, icon: "fas fa-check-circle" }
    ]
  end

  def info_menu_links
    [
      {
        label: "Releases",
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

  # Format date as "Today HH:MM", "Yesterday HH:MM", or "YYYY-MM-DD HH:MM"
  def display_date_short(c)
    return "" unless c
    n = Time.now
    html = ""
    if n.day == c.day && n.month == c.month && n.year == c.year
      html += "Today"
    elsif n.day == c.day + 1 && n.month == c.month && n.year == c.year
      html += "Yesterday"
    else
      html += "#{c.year}-#{"0" if c.month < 10}#{c.month}-#{"0" if c.day < 10}#{c.day}"
    end
    html += " #{"0" if c.hour < 10}#{c.hour}:#{"0" if c.min < 10}#{c.min}"
    raw html
  end

  # Format memory in bytes to human-readable format (b, Kb, Mb, Gb)
  def display_mem(b)
    return '' unless b
    g = b.to_f / 1_000_000_000
    m = b.to_f / 1_000_000
    k = b.to_f / 1_000
    if g < 1
      if m < 1
        if k < 1
          "#{b.round(3 - (b.to_i.to_s.size))}b"
        else
          "#{k.round(3 - (k.to_i.to_s.size))}Kb"
        end
      else
        "#{m.round(3 - (m.to_i.to_s.size))}Mb"
      end
    else
      "#{g.round(3 - (g.to_i.to_s.size))}Gb"
    end
  end
end
