module ApplicationHelper
  def clean_metadata_path(name)
    name.to_s.sub(%r{^/col_attrs/}, '').sub(%r{^/row_attrs/}, '').sub(%r{^/}, '')
  end

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

  def sandbox_self_destruct_countdown(destroy_at)
    return nil unless destroy_at

    remaining_seconds = [(destroy_at - Time.current).to_i, 0].max
    hours = remaining_seconds / 3600
    minutes = (remaining_seconds % 3600) / 60
    seconds = remaining_seconds % 60
    format('%02d:%02d:%02d', hours, minutes, seconds)
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
        label: "Cell metadata schema",
        description: "Cell metadata used by ASAP to annotate single-cell datasets",
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

  def feedback_menu_links
    [
      {
        label: "Discussions",
        description: "Ask questions and share ideas",
        path: "https://github.com/DeplanckeLab/ASAP/discussions",
        icon: "fas fa-comments",
        external: true
      },
      {
        label: "Feature requests and issues",
        description: "Report bugs or suggest improvements",
        path: "https://github.com/DeplanckeLab/ASAP/issues",
        icon: "fab fa-github",
        external: true
      },
      {
        label: "Contact us",
        description: "Reach the ASAP team by email",
        path: contact_home_index_path,
        icon: "fas fa-envelope"
      },
      {
        label: "Rate the app",
        description: "Share your experience with ASAP",
        path: rate_home_index_path,
        icon: "fas fa-star"
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
  
  def param_tooltip(key, h_method_attrs)
    return key.to_s unless h_method_attrs.is_a?(Hash)
    sma = h_method_attrs[key.to_s]
    return key.to_s unless sma.is_a?(Hash)
    parts = []
    desc = sma['description_text'].presence || sma['description'].presence
    parts << desc if desc
    parts << "[DEFAULT=#{sma['default']}]" if sma.key?('default') && sma['default'].to_s.present?
    return key.to_s if parts.empty?
    "#{key}: #{parts.join(' ')}"
  end

  def param_badge_palette(attr_key)
    key = attr_key.to_s
    is_input_data = key.start_with?('input_matrix', 'input_de')
    if is_input_data
      {
        container: 'bg-blue-100 text-blue-700 border-blue-200',
        key: 'text-blue-800',
        value: 'text-blue-600'
      }
    else
      {
        container: 'bg-purple-100 text-purple-700 border-purple-200',
        key: 'text-purple-800',
        value: 'text-purple-600'
      }
    end
  end

  def render_run_param_badge(run:, key:, value:, h_method_attrs:, context: {}, clickable: true)
    tooltip = param_tooltip(key, h_method_attrs)
    h_annots = context[:h_annots] || {}
    h_runs = context[:h_runs] || {}
    h_steps = context[:h_steps] || @h_steps || {}

    dataset_items = []
    candidate_items = if value.is_a?(Hash)
                        [value]
                      elsif value.is_a?(Array) && value.first.is_a?(Hash)
                        value
                      else
                        []
                      end

    candidate_items.each do |item|
      annot_id = item['annot_id'] || item[:annot_id]
      run_id = item['run_id'] || item[:run_id]
      output_dataset = item['output_dataset'] || item[:output_dataset]

      annot = nil
      if annot_id.present?
        annot = h_annots[annot_id.to_i]
        if annot.nil? && defined?(Annot)
          annot = Annot.find_by(id: annot_id)
        end
      end

      label = if annot
                clean_metadata_path(annot.name)
              elsif output_dataset.present?
                clean_metadata_path(output_dataset)
              else
                nil
              end
      next if label.blank?

      dataset_items << {
        label: label,
        annot_id: annot&.id || annot_id,
        run_id: run_id
      }
    end

    if dataset_items.any?
      palette = param_badge_palette(key)
      uniq_items = dataset_items.uniq { |e| [e[:label], e[:annot_id].to_s, e[:run_id].to_s] }
      key_txt = ERB::Util.html_escape(key.to_s)
      tooltip_txt = ERB::Util.html_escape(tooltip.to_s)
      pipeline_url = run ? pipeline_runs_project_path(run.project) : nil
      badges = uniq_items.map do |item|
        item_label = ERB::Util.html_escape(item[:label].to_s)
        clickable_attrs = ''
        if clickable && pipeline_url
          if item[:annot_id].present?
            clickable_attrs = " data-controller='pipeline-runs' data-pipeline-runs-annot-id-value='#{item[:annot_id]}' data-pipeline-runs-url-value='#{pipeline_url}' data-action='click->pipeline-runs#showPipeline' onclick='event.stopPropagation();'"
          elsif item[:run_id].present?
            clickable_attrs = " data-controller='pipeline-runs' data-pipeline-runs-run-id-value='#{item[:run_id]}' data-pipeline-runs-url-value='#{pipeline_url}' data-action='click->pipeline-runs#showPipeline' onclick='event.stopPropagation();'"
          end
        end

        "<span class='inline-flex items-center px-2 py-0.5 rounded text-xs font-medium border #{palette[:container]}#{clickable_attrs.present? ? ' cursor-pointer' : ''}' title='#{tooltip_txt}'#{clickable_attrs}>" \
          "<span class='font-semibold #{palette[:key]}'>#{key_txt}:</span>" \
          "<span class='#{palette[:value]}'>#{item_label}</span>" \
          "</span>"
      end
      return badges.join('')
    end

    value_str = if value.is_a?(Array) || value.is_a?(Hash)
                  value.to_json
                else
                  value.to_s
                end
    value_str = value_str.to_s
    truncated = value_str.length > 80 ? "#{value_str[0..76]}..." : value_str
    key_txt = ERB::Util.html_escape(key.to_s)
    val_txt = ERB::Util.html_escape(truncated)
    tooltip_txt = ERB::Util.html_escape(tooltip.to_s)

    "<span class='inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-gray-100 text-gray-700 border border-gray-200 cursor-help' title='#{tooltip_txt}'>" \
      "<span class='font-semibold text-gray-800'>#{key_txt}:</span>" \
      "<span class='text-gray-600'>#{val_txt}</span>" \
      "</span>"
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
    
    method_attrs_map = if h_std_method_attrs.is_a?(Hash) && h_std_method_attrs.any?
                          nested = h_std_method_attrs[run.std_method_id]
                          if nested.is_a?(Hash)
                            nested
                          else
                            first_val = h_std_method_attrs.values.first
                            (first_val.is_a?(Hash) && (first_val.key?('label') || first_val.key?('default') || first_val.key?('description'))) ? h_std_method_attrs : {}
                          end
                        else
                          {}
                        end

    array = h_attrs.keys.reject { |attr|
      reject_attrs.include?(attr) ||
      (opt[:reject_if_default] && run &&
       (sma = method_attrs_map[attr]).is_a?(Hash) &&
       (attr_default = sma['default']) &&
       attr_default.to_s == h_attrs[attr].to_s)
    }.map { |attr|
      render_run_param_badge(
        run: run,
        key: attr,
        value: h_attrs[attr],
        h_method_attrs: method_attrs_map,
        context: {
          h_annots: opt[:h_annots] || {},
          h_runs: opt[:h_runs] || {},
          h_steps: opt[:h_steps] || {}
        }
      )
    }.reject(&:blank?)

    { datasets: [], attrs: array }
  end
  
  def display_run_attrs(run, h_attrs, h_std_method_attrs, opt)
    h = display_run_attrs_base(run, h_attrs, h_std_method_attrs, opt)
    all_badges = h[:datasets] + h[:attrs]
    return '' if all_badges.empty?
    "<div class='flex flex-wrap gap-1.5 items-center'>" + all_badges.join("") + "</div>"
  end

  def render_results_dataset_sections(h_annots_by_dim, variant: :legacy_button, pluralize_all: false)
    return '' unless h_annots_by_dim.present?

    h_dim = { 1 => 'Cell metadata', 2 => 'Gene metadata', 3 => 'Expression matrix', 4 => 'Other' }

    h_annots_by_dim.keys.sort.map do |dim|
      annots = h_annots_by_dim[dim]
      next if annots.blank?

      subtitle = h_dim[dim] || 'Other'
      if subtitle && annots.size > 1 && (pluralize_all || dim > 2)
        subtitle = subtitle.pluralize
      end

      buttons_html = annots.map { |annot| render_results_dataset_button(annot, dim, variant: variant) }.join(' ')
      "<h4>#{subtitle}</h4><p style='line-height:2.5em'>#{buttons_html}</p>"
    end.compact.join("<br/>\n")
  end

  def render_results_dataset_button(annot, dim, variant: :legacy_button)
    col_name = ([1, 3].include?(dim)) ? 'cell' : 'column'
    row_name = ([2, 3].include?(dim)) ? 'gene' : 'row'
    col_name = col_name.pluralize if annot.nber_cols && annot.nber_cols > 1
    row_name = row_name.pluralize if annot.nber_rows && annot.nber_rows > 1
    categories_count = annot.nber_cats.to_i
    if categories_count <= 0 && annot.categories_json.present?
      parsed_categories = Basic.safe_parse_json(annot.categories_json, nil)
      categories_count =
        if parsed_categories.is_a?(Hash)
          parsed_categories.keys.size
        elsif parsed_categories.is_a?(Array)
          parsed_categories.size
        else
          0
        end
    end
    is_categorical = categories_count > 0 || annot.name.to_s.include?('_clust_')
    categories_badge_html = ''
    if is_categorical
      categories_label = categories_count == 1 ? 'category' : 'categories'
      categories_badge_html = " <span class='inline-flex items-center px-1.5 py-0.5 rounded text-xs font-medium bg-white text-gray-600 border border-gray-300'>#{categories_count} #{categories_label}</span>"
    end
    if is_categorical
      obs_count = if dim.to_i == 1 && annot.nber_rows.present? && annot.nber_rows.to_i > 0
                    annot.nber_rows.to_i
                  elsif annot.nber_cols.present? && annot.nber_cols.to_i > 0 && annot.nber_rows.present? && annot.nber_rows.to_i > 0
                    [annot.nber_cols.to_i, annot.nber_rows.to_i].max
                  elsif annot.nber_cols.present? && annot.nber_cols.to_i > 0
                    annot.nber_cols.to_i
                  else
                    annot.nber_rows.to_i
                  end
      base_col_label = @project&.project_type&.col_label.presence || 'cells'
      obs_label = obs_count == 1 ? base_col_label.to_s.singularize : base_col_label.to_s.pluralize
      primary_badge_html = "<span class='inline-flex items-center px-1.5 py-0.5 rounded text-xs font-medium bg-white text-gray-600 border border-gray-300'>#{obs_count} #{obs_label}</span>"
    else
      primary_badge_html = "<span class='inline-flex items-center px-1.5 py-0.5 rounded text-xs font-medium bg-white text-gray-600 border border-gray-300'>#{annot.nber_cols} #{col_name}</span> <span class='inline-flex items-center px-1.5 py-0.5 rounded text-xs font-medium bg-white text-gray-600 border border-gray-300'>#{annot.nber_rows} #{row_name}</span>"
    end

    if variant.to_sym == :link_chip
      annot_path = Rails.application.routes.url_helpers.annot_path(annot)
      "<a href='#{annot_path}' class='inline-flex items-center gap-1.5 px-3 py-1.5 rounded-md text-sm font-medium bg-gray-100 text-gray-700 border border-gray-200 hover:bg-gray-200 transition-colors'>#{annot.name} #{primary_badge_html}#{categories_badge_html}</a>"
    else
      if is_categorical
        "<button id='annot_#{annot.id}_btn' class='btn btn-outline-secondary btn-sm annot_btn'>#{annot.name} #{primary_badge_html}#{categories_badge_html}</button>"
      else
        "<button id='annot_#{annot.id}_btn' class='btn btn-outline-secondary btn-sm annot_btn'>#{annot.name} <span class='badge badge-light'>#{annot.nber_cols} #{col_name}</span> <span class='badge badge-light'>#{annot.nber_rows} #{row_name}</span></button>"
      end
    end
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
      # Build configuration from database statuses (all styling now comes from DB)
      Status.order(:rank, :id).map do |status|
        key = status.name.to_s.downcase.to_sym
        
        # Use the database status name for display labels
        display_label = status.name.humanize
        
        {
          id: status.id,
          key: key,
          db_name: key,
          color: status.color.presence || 'gray',
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
  # Prefer DB status keys (:pending, :running, :success, :failed).
  # Keep legacy aliases for compatibility with older views.
  def status_icons_by_key
    @status_icons_by_key ||= begin
      config = status_icons_config.index_by { |s| s[:key] }
      config[:waiting] = config[:pending] if config[:pending]
      config[:completed] = config[:success] if config[:success]
      config
    end
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
  # Do NOT use .html_safe here: the JSON must be HTML-encoded when placed
  # inside data-*-value="..." attributes. Stimulus decodes entities automatically.
  def status_icons_json
    status_icons_config.to_json
  end

  # Renders a vertical separator line for the header navigation
  def header_separator
    content_tag(:div, nil, class: "border-l border-gray-700 h-12 ml-3 mr-2")
  end

  # Returns run counts by status from project_steps' nber_runs_json
  # More efficient than counting runs directly
  # Returns { pending: N, running: N, success: N, failed: N }
  def project_run_counts(project)
    totals = { 1 => 0, 2 => 0, 3 => 0, 4 => 0 }
    json_data = project.nber_runs_json.is_a?(String) ? JSON.parse(project.nber_runs_json) : project.nber_runs_json
    json_data ||= {}
    json_data.each do |status_id, count|
      status_key = status_id.to_i
      totals[status_key] = count.to_i if totals.key?(status_key)
    end
    
    {
      pending: totals[1],
      running: totals[2],
      success: totals[3],
      failed: totals[4]
    }
  end

  def visible_step_ids_for_run_counts
    @visible_step_ids_for_run_counts ||= Step.where.not(hidden: true).pluck(:id)
  end

  # Returns the URL to go back to the projects browse page
  # Preserves search query, filters, and pagination from the last visit
  def projects_browse_url
    session[:projects_browse_url].presence || projects_path
  end

  # Returns the URL for viewing a run in the analysis view
  # Always navigates to the project analysis view with the run selected
  # The analysis view will show standard view or custom view based on step.has_std_view
  # @param run [Run] The run object
  # @param project [Project] The project object
  # @param step [Step, nil] Optional step object (fetched from run if not provided)
  # @return [String] The URL to the analysis view for this run
  def run_view_url(run, project, step = nil)
    return '#' unless run && project

    step ||= run.step
    return '#' unless step

    project_path(project, view: 'analysis', step_id: step.id, run_id: run.id)
  end
end
