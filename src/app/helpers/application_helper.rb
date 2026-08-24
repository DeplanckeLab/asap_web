module ApplicationHelper
  # Badges for published public projects (public_at set):
  # - Green closed lock: in the public snapshot (created before public_at); visible to anyone who can read the project in snapshot mode.
  # - Grey open lock: after public_at; only listed for users with full read access (owner/admin). Snapshot-only readers and guests must not see these rows (controller filters enforce that).
  SINGLE_RUN_RESTARTABLE_STATUSES = [1, 2, 3, 4, 6].freeze

  def publication_locked_step_message
    'This analysis is included in the public snapshot and cannot be modified.'
  end

  # True when a single-run step has at least one run frozen in the public snapshot.
  def single_run_step_locked_from_publication?(project, step, runs: nil)
    return false unless project&.publication_lock_active?
    return false unless step && !step.multiple_runs

    step_runs =
      if runs
        Array(runs).compact
      else
        project.runs.where(step_id: step.id).to_a
      end
    step_runs.any? { |run| project.locked_from_publication?(run) }
  end

  # Whether a single-run step can be reset/restarted in the UI or via restart_step.
  def single_run_step_resettable?(project, step, project_step: nil, runs: nil)
    return false unless step && !step.multiple_runs
    return false if single_run_step_locked_from_publication?(project, step, runs: runs)

    project_step ||= ProjectStep.find_by(project_id: project.id, step_id: step.id)
    project_step && SINGLE_RUN_RESTARTABLE_STATUSES.include?(project_step.status_id)
  end

  # Whether result-page refinement controls (e.g. doublet calling) may update parameters.
  def step_result_refinement_allowed?(project, run)
    return false unless project && run
    return false unless analyzable?(project) && editable?(project)
    return false if project.locked_from_publication?(run)

    true
  end

  def publication_visibility_badge(project, record, full_read_access:)
    return ''.html_safe unless project&.publication_lock_active? && record

    if project.locked_from_publication?(record)
      content_tag(:span,
                  class: 'inline-flex items-center px-1.5 py-0.5 rounded text-xs font-medium bg-green-100 text-green-800 border border-green-200 ml-1',
                  title: 'Included in public snapshot') do
        content_tag(:i, '', class: 'fas fa-lock')
      end
    elsif full_read_access
      content_tag(:span,
                  class: 'inline-flex items-center px-1.5 py-0.5 rounded text-xs font-medium bg-gray-100 text-gray-700 border border-gray-300 ml-1',
                  title: 'Not in public snapshot; visible only with full read access to this project') do
        content_tag(:i, '', class: 'fas fa-lock-open')
      end
    else
      ''.html_safe
    end
  end

  def clean_metadata_path(name)
    name.to_s.sub(%r{^/col_attrs/}, '').sub(%r{^/row_attrs/}, '').sub(%r{^/}, '')
  end

  def display_run(run)
    return "Unknown Run" unless run
    "#{run.step&.label || 'Step'} ##{run.num}"
  end

  # Program/opts/args line from command_json (no docker run, no sh -c), for run result UI.
  def run_inner_command_line(run)
    return nil unless run&.command_json.present?

    Basic.run_inner_command_display_string(run.command_json)
  end

  def user_display_name(user, current_user: nil)
    return '-' unless user
    return 'me' if current_user && user.id == current_user.id

    email_prefix = user.email.to_s.split('@').first
    return email_prefix if email_prefix.present?

    user.displayed_name.to_s.presence || '-'
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

  # Format number with thousand delimiters (apostrophe, e.g. 1'234'567)
  def number_with_delimiter(number)
    return "0" if number.nil?
    number.to_s.reverse.gsub(/(\d{3})(?=\d)/, "\\1'").reverse
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

  # Ensembl genome-browser gene URL uses INSDC accession (GCA_...), not assembly.name (AaegL5).
  def ensembl_gene_browser_url(ensembl_id, assembly: nil, project: nil)
    asm = assembly.to_s.strip.presence
    unless asm
      meta = project_ensembl_metadata(project)
      asm = meta&.dig(:ensembl_genome_browser_assembly)
    end
    Scfair::EnsemblGeneUrl.build(ensembl_id: ensembl_id, assembly: asm)
  end

  def project_ensembl_metadata(project)
    return nil unless project

    Scfair::ProjectEnsemblMetadataResolver.call(project)
  rescue StandardError
    nil
  end

  def project_ensembl_assembly(project)
    project_ensembl_metadata(project)&.dig(:ensembl_assembly)
  end

  def project_ensembl_genome_browser_assembly(project)
    project_ensembl_metadata(project)&.dig(:ensembl_genome_browser_assembly)
  end

  def ensembl_gene_browser_link(ensembl_id, assembly: nil, project: nil, html_options: {})
    label = ensembl_id.to_s
    url = ensembl_gene_browser_url(ensembl_id, assembly: assembly, project: project)
    return content_tag(:span, label) if url.blank?

    link_to(
      label,
      url,
      {
        target: '_blank',
        rel: 'noopener noreferrer',
        class: 'text-blue-600 cursor-pointer hover:underline gene-link',
        data: { ensembl_id: ensembl_id }
      }.deep_merge(html_options)
    )
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
        label: "News",
        description: "Manage welcome-page announcements and news history",
        path: news_items_path,
        icon: "fas fa-newspaper"
      },
      {
        label: "Standalone scFAIR checks",
        description: "Review standalone file-check requests and outcomes",
        path: standalone_compliance_checks_path,
        icon: "fas fa-clipboard-check"
      },
      {
        label: "Cross-references",
        description: "Manage identifier types & external links",
        path: cross_references_admin_home_index_path,
        icon: "fas fa-link"
      },
      {
        label: "Ratings",
        description: "Review user ratings and feedback",
        path: ratings_path,
        icon: "fas fa-star"
      },
      {
        label: "Storage usage",
        description: "Disk space, largest directories, and project/FU storage categories",
        path: storage_usages_path,
        icon: "fas fa-hard-drive"
      },
      {
        label: "Guided tours",
        description: "Manage guided tours and their steps",
        path: editor_guided_tours_path,
        icon: "fas fa-route"
      },
      { label: "Tools", path: tools_path, icon: "fas fa-wrench" },
      { label: "Tool Types", path: tool_types_path, icon: "fas fa-tags" },
      { label: "Docker Images", path: docker_images_path, icon: "fas fa-cube" },
      { label: "Docker Builds", path: docker_builds_path, icon: "fas fa-cubes" },
      { label: "Organisms", path: organisms_path, icon: "fas fa-dna" },
      {
        label: "Project types",
        description: "List types and public/private project counts",
        path: project_types_path,
        icon: "fas fa-layer-group"
      },
      { label: "Steps", path: steps_path, icon: "fas fa-list-ol" },
      { label: "Methods", path: std_methods_path, icon: "fas fa-cogs" },
      { label: "Run statuses", path: statuses_path, icon: "fas fa-check-circle" }
    ]
  end

  def get_step_color(step_id)
    colors = ['#3498db', '#e74c3c', '#2ecc71', '#f39c12', '#9b59b6', '#1abc9c', '#34495e']
    colors[step_id % colors.length]
  end

  def guided_tours_for_menu
    tours = GuidedTour.visible.ordered.select(:id, :name)
    return [] unless tours.exists?

    tours
  end

  def guided_tour_start_url(tour_id)
    q = request.query_parameters.merge("guided_tour" => tour_id.to_s)
    "#{request.path}?#{q.to_query}"
  end

  # Same resolution as db/seeds Getting started tour (for highlighting the demo row on /projects).
  def guided_tour_demo_project_for_highlight
    return @guided_tour_demo_project_for_highlight if instance_variable_defined?(:@guided_tour_demo_project_for_highlight)

    @guided_tour_demo_project_for_highlight = Project.guided_tour_demo_project
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
        label: "Atlases",
        description: "FCA and HCA reference pages and entry points",
        path: atlases_path,
        icon: "fas fa-atlas"
      },
      {
        label: "External catalog",
        description: "Candidate datasets from CELLxGENE, Bgee, HCA, GEO",
        path: external_catalog_candidates_path,
        icon: "fas fa-file-import"
      },
      {
        label: "File formats",
        description: "Supported upload and export formats",
        path: file_format_home_index_path,
        icon: "fas fa-file-alt"
      },
      {
        label: "API documentation",
        description: "OpenAPI/Swagger reference for JSON endpoints",
        path: "/api-doc",
        icon: "fas fa-book-open"
      },
      {
        label: "FAQ",
        description: "Frequently asked questions about ASAP",
        path: faq_home_index_path,
        icon: "fas fa-question-circle"
      }
    ].compact
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
        label: "Citing ASAP",
        description: "How to cite ASAP and who references it",
        path: citing_home_index_path,
        icon: "fas fa-quote-right"
      },
      {
        label: "Feature requests and issues",
        description: "Report bugs or suggest improvements",
        path: "https://github.com/DeplanckeLab/asap_web/issues",
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

  def param_field_description(key, h_method_attrs)
    sma = h_method_attrs.is_a?(Hash) ? h_method_attrs[key.to_s] : nil
    return '' unless sma.is_a?(Hash)
    sma['description_text'].presence || sma['description'].presence || ''
  end

  def param_info_badge_html_attrs(key, display_value, h_method_attrs, full_value: nil, pipeline: nil)
    copy_value = (full_value.presence || display_value).to_s
    attrs = [
      %(data-controller="run-param-info"),
      %(data-action="click->run-param-info#toggle"),
      %(data-run-param-info-name-value="#{ERB::Util.html_escape(key.to_s)}"),
      %(data-run-param-info-label-value="#{ERB::Util.html_escape(form_param_label(key, h_method_attrs))}"),
      %(data-run-param-info-description-value="#{ERB::Util.html_escape(param_field_description(key, h_method_attrs))}"),
      %(data-run-param-info-value-value="#{ERB::Util.html_escape(copy_value)}")
    ]
    if pipeline.is_a?(Hash)
      if pipeline[:annot_id].present?
        attrs << %(data-run-param-info-pipeline-annot-id-value="#{pipeline[:annot_id].to_i}")
      end
      if pipeline[:run_id].present?
        attrs << %(data-run-param-info-pipeline-run-id-value="#{pipeline[:run_id].to_i}")
      end
      if pipeline[:url].present?
        attrs << %(data-run-param-info-pipeline-url-value="#{ERB::Util.html_escape(pipeline[:url])}")
      end
    end
    attrs.join(' ')
  end

  def form_param_label(key, h_method_attrs)
    sma = h_method_attrs.is_a?(Hash) ? h_method_attrs[key.to_s] : nil
    return key.to_s.humanize unless sma.is_a?(Hash)
    sma['label'].presence || key.to_s.humanize
  end

  def form_attr_optional?(_attr_name, attr)
    FormAttrConstraints.optional?(_attr_name, attr)
  end

  def form_attr_required?(attr_name, attr)
    FormAttrConstraints.required?(attr_name, attr)
  end

  def format_form_attr_constraint_rule(prefix, rule)
    return nil unless rule.is_a?(Hash)

    attr = rule['attr'] || rule[:attr]
    equals = rule['equals'] || rule[:equals]
    return nil if attr.blank?

    "#{prefix} when #{attr} is #{equals}"
  end

  def form_attr_constraint_lines(attr_name, attr)
    lines = []
    return lines unless attr.is_a?(Hash)

    auto_filled_required_attrs = %w[group_ref group_comp]
    if form_attr_optional?(attr_name, attr)
      lines << 'Optional'
    elsif form_attr_required?(attr_name, attr)
      lines << 'Required'
    end

    widget = attr['widget'].to_s
    min_items = attr['min_nber_items']
    max_items = attr['max_nber_items']
    show_item_constraints = widget == 'input_data' || attr['req_data_structure'] == 'array'
    if show_item_constraints
      exact_count = min_items && max_items && min_items.to_i.positive? &&
                    max_items.to_i.positive? && min_items.to_i == max_items.to_i
      if exact_count
        lines << "Exactly #{min_items.to_i} item#{'s' if min_items.to_i > 1} required"
      else
        if min_items && min_items.to_i.positive?
          lines << "Minimum #{min_items.to_i} item#{'s' if min_items.to_i > 1}"
        end
        if max_items && max_items.to_i.positive?
          lines << "Maximum #{max_items.to_i} item#{'s' if max_items.to_i > 1}"
        end
      end
    end

    if widget != 'select'
      unless attr['min_val_expression'].present? || attr['max_val_expression'].present?
        min_val = attr['min_val']
        max_val = attr['max_val']
        if min_val.present? && max_val.present?
          lines << "Value must be between #{min_val} and #{max_val}"
        elsif min_val.present?
          lines << "Minimum value: #{min_val}"
        elsif max_val.present?
          lines << "Maximum value: #{max_val}"
        end
      end
      lines << "Min value expression: #{attr['min_val_expression']}" if attr['min_val_expression'].present?
      lines << "Max value expression: #{attr['max_val_expression']}" if attr['max_val_expression'].present?
    end

    if attr['valid_types'].is_a?(Array) && attr['valid_types'].any?
      formatted = attr['valid_types'].map { |group| Array(group).join(' or ') }.join('; or ')
      lines << "Accepted data types: #{formatted}"
    end

    if attr['source_steps'].present?
      steps = Array(attr['source_steps']).map { |step| step.to_s.tr('_', ' ') }.join(', ')
      lines << "Available from steps: #{steps}"
    end

    source_methods = attr['source_methods']
    if source_methods.is_a?(Hash) && source_methods.any?
      sm_lines = source_methods.map { |step, methods| "#{step}: #{Array(methods).join(', ')}" }
      lines << "Allowed methods: #{sm_lines.join('; ')}"
    end

    excluded = attr['excluded_source_methods']
    if excluded.is_a?(Hash) && excluded.any?
      ex_lines = excluded.map { |step, methods| "#{step}: exclude #{Array(methods).join(', ')}" }
      lines << "Excluded methods: #{ex_lines.join('; ')}"
    end

    lines << "Requires: #{Array(attr['requires']).join(', ')}" if attr['requires'].present?
    lines << attr['requires_message'].to_s if attr['requires_message'].present?

    constraints = attr['constraints']
    if constraints.is_a?(Hash)
      visible_if = constraints['visible_if']
      required_if = constraints['required_if']
      if visible_if.is_a?(Array) && visible_if.any?
        lines.concat(visible_if.filter_map { |rule| format_form_attr_constraint_rule('Visible', rule) })
      end
      if required_if.is_a?(Array) && required_if.any?
        lines.concat(required_if.filter_map { |rule| format_form_attr_constraint_rule('Required', rule) })
      end
    end

    lines
  end

  def form_attr_validation_type(attr)
    return nil unless attr.is_a?(Hash)

    attr['type'].to_s.strip.presence
  end

  def form_attr_validation_type_badge_html(attr)
    type = form_attr_validation_type(attr)
    return nil if type.blank?

    %(<span class="inline-flex items-center rounded-full bg-blue-50 px-2 py-0.5 text-[10px] font-medium text-blue-700 ring-1 ring-inset ring-blue-200">#{ERB::Util.html_escape(type)}</span>)
  end

  def form_attr_detail_lines(attr)
    lines = []
    return lines unless attr.is_a?(Hash)

    validation_type = form_attr_validation_type(attr)
    lines << "Type: #{validation_type}" if validation_type.present?

    widget = attr['widget'].to_s
    if attr.key?('default')
      default = attr['default']
      unless default.nil? || (default.is_a?(String) && default.empty?)
        lines << "Default: #{default}"
      end
    end
    lines << "Default expression: #{attr['default_expression']}" if attr['default_expression'].present?
    lines << "Placeholder: #{attr['placeholder']}" if attr['placeholder'].present?

    if attr['list'].is_a?(Array) && attr['list'].any? && widget == 'select'
      options = attr['list'].map { |entry| Array(entry).first }.join(', ')
      lines << "Choices: #{options}"
    end

    lines
  end

  def form_attr_info_payload(attr_name, attr)
    h_method_attrs = { attr_name.to_s => attr }
    {
      name: attr_name.to_s,
      label: form_param_label(attr_name, h_method_attrs),
      description: param_field_description(attr_name, h_method_attrs),
      constraints: form_attr_constraint_lines(attr_name, attr),
      details: form_attr_detail_lines(attr)
    }
  end

  def form_attr_help_available?(attr_name, attr)
    payload = form_attr_info_payload(attr_name, attr)
    payload[:description].present? ||
      payload[:constraints].any? ||
      payload[:details].any?
  end

  def form_attr_info_html_attrs(attr_name, attr)
    payload = form_attr_info_payload(attr_name, attr)
    [
      %(data-controller="form-attr-info"),
      %(data-action="click->form-attr-info#toggle"),
      %(data-form-attr-info-payload-value="#{ERB::Util.html_escape(payload.to_json)}")
    ].join(' ')
  end

  # Maps attr_layout_json container_class (Bootstrap grid) to form layout column widths.
  def attr_layout_column_class(container_class)
    case container_class.to_s.strip
    when "col-md-6", "col-6" then "attr-layout-col-half"
    when "col-md-4", "col-4" then "attr-layout-col-third"
    when "col-md-8", "col-8" then "attr-layout-col-two-thirds"
    when "col-md-3", "col-3" then "attr-layout-col-quarter"
    else "attr-layout-col-full"
    end
  end

  def form_param_empty?(value)
    value.nil? ||
      value == "" ||
      (value.is_a?(Array) && value.empty?) ||
      (value.is_a?(Hash) && value.except("default").empty?)
  end

  def display_form_param_value(run, key, value, h_std_method_attrs, context = {})
    method_map = std_method_attrs_map_for_run_display(run, h_std_method_attrs)
    if form_param_empty?(value)
      return "-"
    end
    if value.is_a?(Hash) || (value.is_a?(Array) && value.first.is_a?(Hash))
      badge = render_run_param_badge(
        run: run,
        key: key,
        value: value,
        h_method_attrs: method_map,
        context: context,
        clickable: true
      )
      return badge if badge.present?
    end
    ERB::Util.html_escape(value.to_s)
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

  def gene_set_display_label_cache
    @gene_set_display_label_cache ||= { collections: {}, items: {} }
  end

  def preload_gene_set_display_labels!(project, collection_ids:, item_ids:)
    cache = gene_set_display_label_cache
    missing_collections = Array(collection_ids).map(&:to_i).uniq.reject(&:zero?) - cache[:collections].keys
    missing_items = Array(item_ids).map(&:to_i).uniq.reject(&:zero?) - cache[:items].keys
    return if missing_collections.empty? && missing_items.empty?

    fetched = GlobalGeneSetDisplayLabels.fetch(
      project,
      collection_ids: missing_collections,
      item_ids: missing_items
    )
    cache[:collections].merge!(fetched[:collections])
    cache[:items].merge!(fetched[:items])
  end

  def resolve_select_param_display_value(key, value, h_method_attrs)
    sma = h_method_attrs[key.to_s]
    return value.to_s unless sma.is_a?(Hash)

    list = sma['list']
    return value.to_s unless list.is_a?(Array)

    pair = list.find do |entry|
      next false unless entry.is_a?(Array) && entry.length >= 2
      entry[1].to_s == value.to_s
    end
    pair ? pair[0].to_s : value.to_s
  end

  def resolve_scalar_param_display_value(run, key, value, h_method_attrs)
    key_s = key.to_s
    case key_s
    when 'geneset_source'
      resolve_select_param_display_value(key_s, value, h_method_attrs)
    when 'global_gene_set_collection_id', 'gene_set_id'
      cache = gene_set_display_label_cache
      cache[:collections][value.to_i].presence || value.to_s
    when 'global_gene_set_item_id'
      cache = gene_set_display_label_cache
      cache[:items][value.to_i].presence || value.to_s
    when 'geneset_sel'
      value.to_s
    when 'group_comp'
      de_compared_group_is_complementary?(value) ? 'Complementary' : value.to_s
    else
      value.to_s
    end
  end

  def de_compared_group_is_complementary?(value)
    return true if Basic.de_group_comp_is_complementary?(value)

    v = value.nil? ? '' : value.to_s.strip
    v.casecmp('null').zero?
  end

  def module_score_global_gene_set_badge_labels(h_attrs)
    cache = gene_set_display_label_cache
    collection_label = cache[:collections][h_attrs['global_gene_set_collection_id'].to_i]
    item_label = cache[:items][h_attrs['global_gene_set_item_id'].to_i]
    GlobalGeneSetDisplayLabels.module_score_gene_set_badge_labels(collection_label, item_label)
  end

  def run_attr_layout_order(run)
    std_method = run&.std_method
    return [] unless std_method&.attr_layout_json.present?

    layout = Basic.safe_parse_json(std_method.attr_layout_json, [])
    layout.flat_map do |block|
      Array(block['horiz_elements']).flat_map { |el| Array(el['attr_list']).map(&:to_s) }
    end.uniq
  end

  def sort_run_attr_keys_for_display(attr_keys, layout_order)
    return attr_keys if layout_order.empty?

    order_index = layout_order.each_with_index.to_h
    attr_keys.sort_by.with_index do |key, idx|
      [order_index.fetch(key.to_s, layout_order.length + idx), idx]
    end
  end

  def run_display_visible?(conditions, h_attrs)
    return true if conditions.blank?

    Array(conditions).all? do |condition|
      next false unless condition.is_a?(Hash)
      h_attrs[condition['attr'].to_s].to_s == condition['equals'].to_s
    end
  end

  def run_display_composite_config(attr, method_attrs_map, h_attrs)
    sma = method_attrs_map[attr.to_s]
    return nil unless sma.is_a?(Hash)

    run_display = sma['run_display']
    return nil unless run_display.is_a?(Hash) && run_display['composite']
    return nil unless run_display_visible?(run_display['visible_when'], h_attrs)

    run_display
  end

  def attrs_hidden_by_composite_display(method_attrs_map, h_attrs)
    hidden = []
    method_attrs_map.each do |_attr, sma|
      next unless sma.is_a?(Hash)

      run_display = sma['run_display']
      next unless run_display.is_a?(Hash) && run_display['composite']
      next unless run_display_visible?(run_display['visible_when'], h_attrs)

      hidden.concat(Array(run_display['merge_with']).map(&:to_s))
    end
    hidden.uniq
  end

  def render_composite_run_param_badge(h_attrs, run_display)
    case run_display['resolver'].to_s
    when 'global_gene_set_item'
      gene_set_labels = module_score_global_gene_set_badge_labels(h_attrs)
      return nil if gene_set_labels[:display].blank?

      render_simple_param_badge(
        key: 'gene_set',
        key_label: run_display['composite_label'].presence || 'Gene set',
        value: gene_set_labels[:display],
        full_value: gene_set_labels[:tooltip],
        h_method_attrs: { 'gene_set' => { 'label' => run_display['composite_label'].presence || 'Gene set', 'description' => run_display['description'].to_s } },
        palette_key: 'gene_set'
      )
    end
  end

  def composite_run_param_txt(h_attrs, run_display)
    case run_display['resolver'].to_s
    when 'global_gene_set_item'
      gene_set_labels = module_score_global_gene_set_badge_labels(h_attrs)
      return nil if gene_set_labels[:display].blank?
      label = run_display['composite_label'].presence || 'Gene set'
      "#{label}:#{gene_set_labels[:display]}"
    end
  end

  def prepare_run_attr_keys_for_display(run, h_attrs, method_attrs_map, reject_attrs, reject_if_default)
    attr_keys = h_attrs.keys.reject { |attr|
      reject_attrs.include?(attr) ||
      reject_default_run_param?(attr, h_attrs, method_attrs_map, reject_if_default)
    }
    attr_keys -= attrs_hidden_by_composite_display(method_attrs_map, h_attrs)
    sort_run_attr_keys_for_display(attr_keys, run_attr_layout_order(run))
  end

  def render_simple_param_badge(key:, key_label:, value:, h_method_attrs:, palette_key:, full_value: nil, pipeline: nil)
    palette = param_badge_palette(palette_key)
    key_txt = ERB::Util.html_escape(key_label.to_s)
    val_txt = ERB::Util.html_escape(value.to_s)
    truncated = val_txt.length > 80 ? "#{val_txt[0..76]}..." : val_txt
    info_attrs = param_info_badge_html_attrs(key, value, h_method_attrs, full_value: full_value, pipeline: pipeline)

    "<span class='inline-flex items-center px-2 py-0.5 rounded text-xs font-medium border #{palette[:container]} cursor-pointer' #{info_attrs}>" \
      "<span class='font-semibold #{palette[:key]}'>#{key_txt}:</span>" \
      "<span class='#{palette[:value]}'>#{truncated}</span>" \
      "</span>"
  end

  def render_run_param_badge(run:, key:, value:, h_method_attrs:, context: {}, clickable: true)
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

      full_value = if annot
                     annot.name.to_s
                   elsif output_dataset.present?
                     output_dataset.to_s
                   else
                     label
                   end

      dataset_items << {
        label: label,
        full_value: full_value,
        annot_id: annot&.id || annot_id,
        run_id: run_id
      }
    end

    if dataset_items.any?
      palette = param_badge_palette(key)
      uniq_items = dataset_items.uniq { |e| [e[:label], e[:annot_id].to_s, e[:run_id].to_s] }
      key_txt = ERB::Util.html_escape(form_param_label(key, h_method_attrs))
      pipeline_url = (clickable && run) ? pipeline_runs_project_path(run.project) : nil
      badges = uniq_items.map do |item|
        item_label = ERB::Util.html_escape(item[:label].to_s)
        pipeline = nil
        if pipeline_url && (item[:annot_id].present? || item[:run_id].present?)
          pipeline = { url: pipeline_url }
          pipeline[:annot_id] = item[:annot_id] if item[:annot_id].present?
          pipeline[:run_id] = item[:run_id] if item[:run_id].present?
        end
        info_attrs = param_info_badge_html_attrs(key, item[:label], h_method_attrs, full_value: item[:full_value], pipeline: pipeline)

        "<span class='inline-flex items-center px-2 py-0.5 rounded text-xs font-medium border #{palette[:container]} cursor-pointer' #{info_attrs}>" \
          "<span class='font-semibold #{palette[:key]}'>#{key_txt}:</span>" \
          "<span class='#{palette[:value]}'>#{item_label}</span>" \
          "</span>"
      end
      return badges.join('')
    end

    if key.to_s == 'covariates' && value.is_a?(Array) && value.empty?
      palette = param_badge_palette(key)
      key_txt = ERB::Util.html_escape(form_param_label(key, h_method_attrs))
      info_attrs = param_info_badge_html_attrs(key, 'none', h_method_attrs)
      return (
        "<span class='inline-flex items-center px-2 py-0.5 rounded text-xs font-medium border #{palette[:container]} cursor-pointer' #{info_attrs}>" \
          "<span class='font-semibold #{palette[:key]}'>#{key_txt}:</span>" \
          "<span class='#{palette[:value]} italic'>none</span>" \
          "</span>"
      ).html_safe
    end

    if key.to_s == 'group_comp' && de_compared_group_is_complementary?(value)
      palette = param_badge_palette(key)
      key_txt = ERB::Util.html_escape(form_param_label(key, h_method_attrs))
      info_attrs = param_info_badge_html_attrs(key, 'Complementary', h_method_attrs)
      return (
        "<span class='inline-flex items-center px-2 py-0.5 rounded text-xs font-medium border #{palette[:container]} cursor-pointer' #{info_attrs}>" \
          "<span class='font-semibold #{palette[:key]}'>#{key_txt}:</span>" \
          "<span class='#{palette[:value]} italic'>Complementary</span>" \
          "</span>"
      ).html_safe
    end

    display_value = if value.is_a?(Array) || value.is_a?(Hash)
                      value.to_json
                    else
                      resolve_scalar_param_display_value(run, key, value, h_method_attrs)
                    end
    render_simple_param_badge(
      key: key,
      key_label: form_param_label(key, h_method_attrs),
      value: display_value,
      h_method_attrs: h_method_attrs,
      palette_key: key
    )
  end

  # When std_method attrs_json defines "default" for a param, run badges and display_run_attrs_txt
  # omit that param if h_attrs[param].to_s matches (use sma.key?("default") so false / 0 work).
  # opt[:reject_if_default] defaults to true; pass false to show every stored param for that render.
  def skip_reject_default_for_display?(attr, method_attrs_map)
    sma = method_attrs_map[attr.to_s]
    sma.is_a?(Hash) && sma.dig('run_display', 'show_when_default') == true
  end

  def reject_default_run_param?(attr, h_attrs, method_attrs_map, reject_if_default)
    return false unless reject_if_default
    return false if skip_reject_default_for_display?(attr, method_attrs_map)

    sma = method_attrs_map[attr.to_s]
    sma.is_a?(Hash) && sma.key?('default') && sma['default'].to_s == h_attrs[attr].to_s
  end

  def std_method_attrs_map_for_run_display(run, h_std_method_attrs)
    return {} unless run && h_std_method_attrs.is_a?(Hash) && h_std_method_attrs.any?

    nested = h_std_method_attrs[run.std_method_id]
    if nested.is_a?(Hash)
      nested
    else
      first_val = h_std_method_attrs.values.first
      (first_val.is_a?(Hash) && (first_val.key?('label') || first_val.key?('default') || first_val.key?('description'))) ? h_std_method_attrs : {}
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
    
    method_attrs_map = std_method_attrs_map_for_run_display(run, h_std_method_attrs)
    reject_if_default = opt.fetch(:reject_if_default, true)

    if run&.project_id
      collection_ids = [h_attrs['global_gene_set_collection_id'], h_attrs['gene_set_id']].compact
      item_ids = [h_attrs['global_gene_set_item_id']].compact
      if collection_ids.any? || item_ids.any?
        project = run.project || Project.find_by(id: run.project_id)
        if project
          preload_gene_set_display_labels!(
            project,
            collection_ids: collection_ids,
            item_ids: item_ids
          )
        end
      end
    end

    context = {
      h_annots: opt[:h_annots] || {},
      h_runs: opt[:h_runs] || {},
      h_steps: opt[:h_steps] || {}
    }

    attr_keys = prepare_run_attr_keys_for_display(run, h_attrs, method_attrs_map, reject_attrs, reject_if_default)

    array = attr_keys.map { |attr|
      composite_cfg = run_display_composite_config(attr, method_attrs_map, h_attrs)
      if composite_cfg
        render_composite_run_param_badge(h_attrs, composite_cfg)
      else
        render_run_param_badge(
          run: run,
          key: attr,
          value: h_attrs[attr],
          h_method_attrs: method_attrs_map,
          context: context
        )
      end
    }.reject(&:blank?)

    { datasets: [], attrs: array }
  end
  
  def display_run_attrs(run, h_attrs, h_std_method_attrs, opt)
    h = display_run_attrs_base(run, h_attrs, h_std_method_attrs, opt)
    all_badges = h[:datasets] + h[:attrs]
    return '' if all_badges.empty?
    "<div class='flex flex-wrap gap-1.5 items-center'>" + all_badges.join("") + "</div>"
  end

  # Plain-text run parameters for reproduction shell scripts (legacy ASAP get_commands).
  def display_run_attrs_txt(run, h_attrs, h_std_method_attrs, opt = {})
    return '' unless run && h_attrs.is_a?(Hash)

    reject_attrs = if defined?(@h_dashboard_card) && @h_dashboard_card && @h_dashboard_card[run.step_id]
                     @h_dashboard_card[run.step_id]['reject_attrs'] || []
                   else
                     []
                   end

    method_map = std_method_attrs_map_for_run_display(run, h_std_method_attrs)
    reject_if_default = opt.fetch(:reject_if_default, true)

    if run&.project_id
      collection_ids = [h_attrs['global_gene_set_collection_id'], h_attrs['gene_set_id']].compact
      item_ids = [h_attrs['global_gene_set_item_id']].compact
      if collection_ids.any? || item_ids.any?
        project = run.project || Project.find_by(id: run.project_id)
        if project
          preload_gene_set_display_labels!(
            project,
            collection_ids: collection_ids,
            item_ids: item_ids
          )
        end
      end
    end

    context = { h_steps: opt[:h_steps] || @h_steps || {} }
    h_steps = context[:h_steps]
    attr_keys = prepare_run_attr_keys_for_display(run, h_attrs, method_map, reject_attrs, reject_if_default)

    list = []
    attr_keys.each do |attr|
      composite_cfg = run_display_composite_config(attr, method_map, h_attrs)
      if composite_cfg
        txt = composite_run_param_txt(h_attrs, composite_cfg)
        list.push(txt) if txt.present?
        next
      end

      v = h_attrs[attr]
      txt = ''
      list_datasets = []
      if v.is_a?(Hash) && v['run_id']
        list_datasets.push(v)
      elsif v.is_a?(Array) && v[0].is_a?(Hash) && v[0]['run_id']
        list_datasets = v
      else
        label = form_param_label(attr, method_map)
        display_v = if v.is_a?(Array) || v.is_a?(Hash)
                      v.to_json
                    else
                      resolve_scalar_param_display_value(run, attr, v, method_map)
                    end
        txt = "#{label}:#{display_v}" if method_map[attr]
      end
      list_datasets.each_index do |_dataset_i|
        v_ds = list_datasets[_dataset_i]
        tmp_run = v_ds && v_ds['run_id'] ? Run.find_by(id: v_ds['run_id']) : nil
        tmp_step = tmp_run ? h_steps[tmp_run.step_id] : nil
        txt = if tmp_run && tmp_step
                "#{attr}:#{tmp_step.name}" + (tmp_step.multiple_runs? ? " ##{tmp_run.num}" : '')
              else
                "#{attr}:NA"
              end
      end
      list.push(txt)
    end
    list.reject(&:blank?).join(' ')
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

  # Status id => { ui_label, bg, text } for run row badges (StepSelectorController#getStatusConfig).
  # Same fields as Status#ui_label, #run_badge_bg_class, #run_badge_text_class.
  # Do not use .html_safe: value is HTML-escaped inside data-* attributes.
  def run_status_badge_options_json
    Status.order(:id).each_with_object({}) do |st, h|
      h[st.id.to_s] = {
        'ui_label' => st.ui_label,
        'bg' => st.run_badge_bg_class,
        'text' => st.run_badge_text_class
      }
    end.to_json
  end

  # Returns the badge info for a run's status by reading the corresponding
  # Status row from the database. Callers pass an optional +h_statuses+
  # ({id => Status}) to avoid per-run lookups when rendering long lists.
  # Keys are the same as +run_status_badge_options_json+ (ui_label, bg, text).
  def run_status_badge_for(run, h_statuses = nil)
    return { ui_label: '', bg: '', text: '' } unless run
    status = (h_statuses && h_statuses[run.status_id]) || Status.find_by(id: run.status_id)
    return { ui_label: '', bg: '', text: '' } unless status
    {
      ui_label: status.ui_label,
      bg: status.run_badge_bg_class,
      text: status.run_badge_text_class
    }
  end

  # Renders a vertical separator line for the header navigation
  def header_separator
    content_tag(:div, nil, class: "border-l border-gray-700 h-12 ml-3 mr-2")
  end

  # Returns run counts by status from project_steps' nber_runs_json
  # More efficient than counting runs directly
  # Returns { pending: N, running: N, success: N, failed: N }
  #
  # The `:failed` bucket aggregates both failed (status_id 4) and stopped
  # (status_id 5) runs: in summarized displays (projects list, project
  # header, pipeline left panel) they are shown together under a single
  # failed icon with a "Failed/Stopped" tooltip.
  #
  # For published public projects (public_at set), guests and other snapshot readers must only
  # see runs in the public snapshot (same rule as run_visible_under_publication_rules? / green lock).
  def project_run_counts(project)
    visible_ids = visible_step_ids_for_run_counts
    if project.publication_lock_active? && publication_snapshot_reader?(project)
      tallies = { 1 => 0, 2 => 0, 3 => 0, 4 => 0, 5 => 0 }
      project.runs
             .where(step_id: visible_ids)
             .where('runs.created_at < ?', project.public_at)
             .group(:status_id)
             .count
             .each do |status_id, n|
        k = status_id.to_i
        tallies[k] = n if tallies.key?(k)
      end
      {
        pending: tallies[1],
        running: tallies[2],
        success: tallies[3],
        failed: tallies[4] + tallies[5]
      }
    else
      totals = { 1 => 0, 2 => 0, 3 => 0, 4 => 0, 5 => 0 }
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
        failed: totals[4] + totals[5]
      }
    end
  end

  # Tooltip label used in summarized status displays (projects list, project
  # header, pipeline left panel grid). Stopped runs are grouped under the
  # failed icon, so the failed bucket is labeled "Failed/Stopped".
  def run_summary_tooltip_label(key)
    case key.to_sym
    when :failed
      'Failed/Stopped'
    when :waiting, :pending
      'Pending'
    when :running
      'Running'
    when :completed, :success
      'Success'
    else
      key.to_s.humanize
    end
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

  # Lowercase blob of ActiveRecord column values for client-side table filtering.
  def activerecord_attribute_search_blob(*records)
    fragments = []
    records.compact.each do |record|
      next unless record.respond_to?(:attributes)

      fragments.concat(record.attributes.values.map { |v| v.nil? ? '' : v.to_s })
    end
    fragments.join(' ')
  end

  # Std methods index: std_method columns, related step and docker images, display-only tokens.
  def std_method_index_row_filter_text(std_method)
    step = std_method.step
    text = activerecord_attribute_search_blob(
      std_method,
      step,
      std_method.docker_image,
      step&.docker_image
    )
    text += " #{std_method.command_program}" if std_method.respond_to?(:command_program)
    text += " #{std_method.obsolete? ? 'no' : 'yes'}"
    text.downcase
  end

  # Steps index: step columns and optional docker image.
  def step_index_row_filter_text(step)
    activerecord_attribute_search_blob(step, step.docker_image).downcase
  end

  # Std methods index table: same visible cell text as the index view (excludes action column).
  def std_method_index_row_filter_text_table_columns(std_method)
    step = std_method.step
    step_cell =
      if step
        (step.label.presence || step.name).to_s
      else
        '—'
      end
    [
      std_method.id.to_s,
      step_cell,
      (std_method.name.presence || '—').to_s,
      (std_method.label.presence || '—').to_s,
      (std_method.command_program.presence || '—').to_s,
      (std_method.speed_id.presence ? std_method.speed_id.to_s : '—'),
      (std_method.obsolete? ? 'no' : 'yes')
    ].join(' ').downcase
  end

  # Steps index table: same visible cell text as the index view (excludes action column).
  def step_index_row_filter_text_table_columns(step)
    [
      step.id.to_s,
      (step.rank.presence || '—').to_s,
      (step.obj_name.presence || '—').to_s,
      (step.name.presence || '—').to_s,
      (step.label.presence || '—').to_s
    ].join(' ').downcase
  end

  DEFAULT_META_DESCRIPTION = 'A collaborative portal to analyze single-cell transcriptomics data.'.freeze

  def default_meta_description
    DEFAULT_META_DESCRIPTION
  end

  def seo_site_base_url
    ENV.fetch('SERVER_URL').chomp('/')
  end

  def seo_page_title
    if content_for?(:meta_title)
      strip_tags(content_for(:meta_title))
    elsif content_for?(:title)
      strip_tags(content_for(:title))
    else
      'ASAP'
    end
  end

  def seo_meta_description
    content_for(:meta_description).presence || default_meta_description
  end

  def seo_canonical_url
    "#{seo_site_base_url}#{request.fullpath}"
  end

  def seo_og_image_url
    path = content_for(:og_image_path).presence || '/icon.png'
    path = "/#{path.delete_prefix('/')}"
    "#{seo_site_base_url}#{path}"
  end
end
