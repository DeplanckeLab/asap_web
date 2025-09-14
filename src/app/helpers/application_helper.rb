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
  
  def exportable?(project)
    # Check if project has runs and is not in sandbox mode or user is admin
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
end

# Basic utility class for JSON parsing
class Basic
  def self.safe_parse_json(json_string, default = {})
    return default unless json_string.present?
    JSON.parse(json_string) rescue default
  end
end
