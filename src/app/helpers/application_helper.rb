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

  def get_step_color(step_id)
    colors = ['#3498db', '#e74c3c', '#2ecc71', '#f39c12', '#9b59b6', '#1abc9c', '#34495e']
    colors[step_id % colors.length]
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
        label: "Project types",
        description: "Available project types and their configurations",
        path: project_types_path,
        icon: "fas fa-layer-group"
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

  # Format memory in bytes to human-readable format (B, KB, MB, GB, TB)
  # Uses binary conversion (1024) to match system standard
  def display_mem(b)
    return '' unless b
    t = b.to_f / (1024.0 ** 4)  # TB: 1024^4 bytes
    g = b.to_f / (1024.0 ** 3)  # GB: 1024^3 bytes
    m = b.to_f / (1024.0 ** 2)  # MB: 1024^2 bytes
    k = b.to_f / 1024.0         # KB: 1024 bytes
    if t >= 1
      precision = [0, 3 - t.to_i.to_s.size].max
      "#{t.round(precision)}TB"
    elsif g >= 1
      precision = [0, 3 - g.to_i.to_s.size].max
      "#{g.round(precision)}GB"
    elsif m >= 1
      precision = [0, 3 - m.to_i.to_s.size].max
      "#{m.round(precision)}MB"
    elsif k >= 1
      precision = [0, 3 - k.to_i.to_s.size].max
      "#{k.round(precision)}KB"
    else
      precision = [0, 3 - b.to_i.to_s.size].max
      "#{b.round(precision)}B"
    end
  end
  
  # Display run attributes
  def display_run_attrs_base(run, h_attrs, h_std_method_attrs, opt)
    return { datasets: [], attrs: [] } unless run && h_attrs
    
    input_lineage_class = opt[:input_lineage_class] || 'input_lineage'
    array_dataset = []
    reject_attrs = []
    if defined?(@h_dashboard_card) && @h_dashboard_card && @h_dashboard_card[run.step_id] && @h_dashboard_card[run.step_id]["reject_attrs"]
      reject_attrs = @h_dashboard_card[run.step_id]["reject_attrs"]
    end
    
    array = h_attrs.keys.reject { |attr|
      reject_attrs.include?(attr) ||
      (opt[:reject_if_default] && run && h_std_method_attrs && h_std_method_attrs[run.std_method_id] &&
       (std_method_attr = h_std_method_attrs[run.std_method_id][attr]) &&
       (attr_default = std_method_attr['default']) &&
       attr_default.to_s == h_attrs[attr].to_s)
    }.map { |attr|
      v = h_attrs[attr]
      txt = ''
      list_datasets_by_attr_name = {}
      
      if v.is_a?(Hash) && v['run_id']
        list_datasets_by_attr_name[attr] ||= []
        list_datasets_by_attr_name[attr].push(v)
      elsif v.is_a?(Array) && v[0].is_a?(Hash) && v[0]['run_id']
        list_datasets_by_attr_name[attr] = v
      else
        std_method_attr = (h_std_method_attrs && h_std_method_attrs[run.std_method_id]) ? h_std_method_attrs[run.std_method_id][attr] : nil
        if std_method_attr
          txt = "<span class='badge badge-light cursor-help wrap' data-toggle='tooltip' data-placement='bottom' title=\"" +
            [std_method_attr['label'], (std_method_attr['description_text'] || std_method_attr['description'] || 'No description')].select { |e| e && !e.empty? }.join(": ") +
            "\">#{attr}:#{v.to_s}</span>"
        else
          txt = "<span class='badge badge-light'>#{attr}:#{v.to_s}</span>"
        end
      end
      
      # Get annots for datasets
      annot_ids = list_datasets_by_attr_name.values.flatten.map { |e| e['annot_id'] }.compact.uniq
      h_annots = {}
      if annot_ids.any? && defined?(Annot)
        Annot.where(id: annot_ids).each { |a| h_annots[a.id] = a }
      end
      
      list_datasets_by_attr_name.each_key do |attr_name|
        if list_datasets_by_attr_name[attr_name].size < 10
          list_datasets_by_attr_name[attr_name].each do |v|
            if v['annot_id'] && h_annots[v['annot_id']]
              v['output_dataset'] = h_annots[v['annot_id']].name
            end
            tmp_run = (defined?(Run) && v['run_id']) ? Run.find_by(id: v['run_id']) : nil
            tmp_step = (tmp_run && @h_steps) ? @h_steps[tmp_run.step_id] : nil
            if tmp_run && tmp_step
              additional_classes = input_lineage_class + ' pointer'
              displayed_val = ''
              if v['output_dataset'] && m = v['output_dataset'].match(/^\/.{3}_attrs\/(.+)/)
                displayed_val = m[1]
              else
                displayed_val = "#{tmp_step.name}" + ((tmp_step.multiple_runs) ? " ##{tmp_run.num}" : "")
              end
              array_dataset.push "<span id='input_lineage_#{tmp_run.id}' class='badge badge-dark #{additional_classes}'>#{attr}:#{displayed_val}</span>"
            else
              array_dataset.push "<span class='badge badge-secondary'>#{attr}:NA</span>"
            end
          end
        else
          array_dataset.push "<span class='badge badge-secondary'>#{attr}:#{list_datasets_by_attr_name[attr_name].size} datasets</span>"
        end
      end
      
      txt
    }
    
    { datasets: array_dataset, attrs: array }
  end
  
  def display_run_attrs(run, h_attrs, h_std_method_attrs, opt)
    h = display_run_attrs_base(run, h_attrs, h_std_method_attrs, opt)
    '<p>' + h[:datasets].join(" ") + " " + h[:attrs].join(" ") + "</p>"
  end
  
  def display_download_btn(run, h_file)
    return "" unless h_file && h_file[:h_output]
    
    h_output = h_file[:h_output]
    title = ""
    h_filename = {
      'output.loom' => 'Loom file',
      'output.json' => 'JSON file'
    }
    
    if h_file[:datasets] && h_file[:datasets].size > 0
      title = "title='Added/changed datasets: " +
        h_file[:datasets].map { |d| d[:name] + ((d[:dataset_size]) ? " [#{display_mem(d[:dataset_size])}]" : '') }.join(", ") + "'"
    end
    
    if h_output["size"] && h_output["size"] > 0
      filename = h_filename[h_output["filename"]] || h_output["filename"] || 'file'
      file_size = display_mem(h_output["size"])
      result = "<a href='#{get_file_project_path(run.project, onum: h_output["onum"], run_id: run.id)}' class='inline-flex items-center gap-1.5 px-3 py-1.5 rounded-md text-sm font-medium bg-gray-100 text-gray-700 border border-gray-200 hover:bg-gray-200 transition-colors' #{title}>"
      result += "<span>#{filename}</span>"
      result += "<span class='inline-flex items-center px-1.5 py-0.5 rounded text-xs font-medium bg-white text-gray-600 border border-gray-300'>#{file_size}</span>"
      result += " <span class='link_to_loom_tuto info-btn pointer'><i class='fas fa-info-circle text-xs'></i></span>" if h_output["filename"] == 'output.loom'
      result += "</a>"
      result
    else
      ""
    end
  end
  
  def display_run2(run, step, std_method)
    return "" unless run && step
    step_label = step.label || step.name
    method_label = (std_method && std_method.label) ? std_method.label : ''
    if step.multiple_runs
      "<span id='show_run_#{run.id}' class='show_link show_run_link pointer'><b>##{run.num}</b> #{step_label} #{method_label}</span>"
    else
      "<span id='show_run_#{run.id}' class='show_link show_run_link pointer'><b>##{run.num}</b> #{step_label}</span>"
    end
  end

  # Build card title for run panel
  # @param run [Run] The run object
  # @param step [Step] The step object
  # @param std_method [StdMethod, nil] The standard method object
  # @return [String] The formatted card title
  def run_card_title(run, step, std_method)
    return 'N/A' unless run && step
    
    std_method_name = std_method ? (std_method.label.presence || std_method.name.presence || 'N/A') : 'N/A'
    
    if step.multiple_runs
      step_name = step.label.presence || step.name.humanize
      run_number = run.num || run.id
      "#{step_name} ##{run_number} #{std_method_name}"
    else
      std_method_name
    end
  end

  # Returns status icons configuration from database
  # Each status includes: key, icon_base, icon_spin, active_color, inactive_color, label
  def status_icons_config
    @status_icons_config ||= begin
      # Map status IDs to canonical keys used in views
      # Views use status_id 1,2,3,4 and reference them as waiting/running/completed/failed
      id_to_key = {
        1 => :waiting,   # DB name: pending
        2 => :running,   # DB name: running
        3 => :completed, # DB name: success
        4 => :failed     # DB name: failed
      }
      
      # Build configuration from database statuses (all styling now comes from DB)
      Status.order(:rank, :id).map do |status|
        key = id_to_key[status.id] || status.name.downcase.to_sym
        
        # Use the canonical key for display labels (Waiting, Running, Completed, Failed)
        display_label = key.to_s.humanize
        
        {
          id: status.id,
          key: key,
          icon_base: status.icon_class.presence || 'fas fa-circle',
          icon_spin: status.icon_spin.presence || '',
          active_color: status.active_color.presence || 'text-gray-500',
          inactive_color: status.inactive_color.presence || 'text-gray-300',
          label: display_label,
          tooltip_label: display_label
        }
      end
    end
  end

  # Returns a hash of status icons keyed by canonical key (symbol)
  # This allows views to use :waiting, :running, :completed, :failed regardless of database names
  def status_icons_by_key
    @status_icons_by_key ||= status_icons_config.index_by { |s| s[:key] }
  end

  # Returns a hash of status icons keyed by status ID
  def status_icons_by_id
    @status_icons_by_id ||= status_icons_config.index_by { |s| s[:id] }
  end

  # Get icon class for a specific status (by name or ID)
  def status_icon_class(status_identifier)
    config = if status_identifier.is_a?(Integer)
               status_icons_by_id[status_identifier]
             else
               status_icons_by_key[status_identifier.to_s.downcase.to_sym]
             end
    config&.dig(:icon_base) || 'fas fa-circle'
  end

  # Returns status icons config as JSON for JavaScript consumption
  def status_icons_json
    status_icons_config.to_json.html_safe
  end

  # Renders a vertical separator line for the header navigation
  def header_separator
    content_tag(:div, nil, class: "border-l border-gray-700 h-12 ml-3 mr-2")
  end

  # Returns run counts by status from project_steps' nber_runs_json
  # More efficient than counting runs directly
  # Returns { waiting: N, running: N, completed: N, failed: N }
  def project_run_counts(project)
    totals = { 1 => 0, 2 => 0, 3 => 0, 4 => 0 }
    
    project.project_steps.each do |ps|
      next if ps.nber_runs_json.blank?
      
      json_data = ps.nber_runs_json.is_a?(String) ? JSON.parse(ps.nber_runs_json) : ps.nber_runs_json
      json_data.each do |status_id, count|
        status_key = status_id.to_i
        totals[status_key] = (totals[status_key] || 0) + count.to_i if totals.key?(status_key)
      end
    end
    
    {
      waiting: totals[1],
      running: totals[2],
      completed: totals[3],
      failed: totals[4]
    }
  end
end
