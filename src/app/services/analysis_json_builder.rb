# frozen_string_literal: true

# Builds a scFAIR analysis_json document from ASAP Project / Run / Step / StdMethod rows.
# Spec: https://github.com/scFAIR/scFAIR_schema/blob/main/schema/7.1.0/schema_analysis_json.md
class AnalysisJsonBuilder
  SCHEMA_VERSION = '7.1.0+scfair1.0'
  # Storage key in uns (H5AD) /attrs (Loom). The schema document is schema_analysis_json.md.
  ATTR_NAME = 'analysis_pipeline'
  LOOM_ATTR_PATH = "/attrs/#{ATTR_NAME}"
  LEGACY_ATTR_NAME = 'analysis_json'
  LEGACY_LOOM_ATTR_PATH = "/attrs/#{LEGACY_ATTR_NAME}"

  STEP_CATEGORY_BY_NAME = {
    'parsing' => 'Parsing',
    'doublet_calling' => 'Doublet Detection',
    'cell_filtering' => 'Cell Filtering',
    'gene_filtering' => 'Gene Filtering',
    'imputation' => 'Imputation',
    'normalization' => 'Normalization',
    'hvg' => 'Feature Selection',
    'removing_covariates' => 'Batch Correction',
    'scaling' => 'Scaling',
    'pca_sc' => 'Dimensionality Reduction',
    'pca' => 'Dimensionality Reduction',
    'dim_reduction' => 'Dimensionality Reduction',
    'tsne' => 'Embedding',
    'umap' => 'Embedding',
    'clustering' => 'Clustering',
    'de' => 'Differential Expression',
    'ge' => 'Gene Set Enrichment',
    'module_score' => 'Gene Set Enrichment',
    'markers' => 'Marker Gene Detection',
    'marker_enrich' => 'Gene Set Enrichment',
    'trajectory' => 'Trajectory Analysis',
    'heatmap' => 'Visualization',
    'corr_heatmap' => 'Visualization',
    'cell_scatter' => 'Visualization',
    'cell_selection' => 'Subsetting',
    'import_metadata' => 'Other',
    'metadata_expr' => 'Other',
    'summary' => 'Report Generation',
    'figures' => 'Report Generation'
  }.freeze

  SEED_ATTR_KEYS = %w[seed random_seed random_state random.seed].freeze

  class << self
    def call(project:, loom_filepath:)
      new(project: project, loom_filepath: loom_filepath).call
    end
  end

  def initialize(project:, loom_filepath:)
    @project = project
    @loom_filepath = loom_filepath.to_s.sub(%r{\A/+}, '')
    @project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + @project.user_id.to_s + @project.key
  end

  def call
    version = @project.version
    h_env = Basic.safe_parse_json(version&.env_json, {})
    asap_run = h_env.dig('docker_images', 'asap_run') || {}
    pipeline_version = asap_run['tag'].presence || asap_run['version']&.to_s
    pipeline_version = "v#{pipeline_version}" if pipeline_version.present? && !pipeline_version.to_s.start_with?('v')

    {
      'schema_version' => SCHEMA_VERSION,
      'pipeline_name' => 'ASAP',
      'pipeline_version' => pipeline_version,
      'pipeline_description' => 'ASAP analysis pipeline reconstructed from project runs stored in the database.',
      'pipeline_url' => pipeline_url,
      'creation_date' => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ'),
      'steps' => relevant_runs.map { |run| build_step(run, h_env) }
    }
  end

  private

  def pipeline_url
    server = ENV['SERVER_URL'].to_s.chomp('/')
    return nil if server.blank?

    "#{server}/projects/#{@project.key}"
  end

  def success_status_id
    @success_status_id ||= Status.find_by(name: 'success')&.id
  end

  def relevant_runs
    return Run.none if success_status_id.nil? || @loom_filepath.blank?

    seed_ids = Annot.where(project_id: @project.id, filepath: @loom_filepath)
                    .pluck(:run_id, :store_run_id, :ori_run_id)
                    .flatten
                    .compact
                    .map(&:to_i)
                    .reject(&:zero?)
                    .uniq
    return Run.none if seed_ids.empty?

    lineage_ids = Run.where(id: seed_ids).flat_map do |run|
      ancestors = run.lineage_run_ids.to_s.split(',').map(&:strip).reject(&:blank?).map(&:to_i)
      ancestors + [run.id]
    end.uniq

    Run.where(project_id: @project.id, id: lineage_ids, status_id: success_status_id)
       .includes(:step, :std_method, docker_build: :docker_image)
       .order(:id)
       .to_a
  end

  def build_step(run, h_env)
    step = run.step
    std_method = run.std_method
    h_cmd = Basic.safe_parse_json(run.command_json, {})
    h_attrs = Basic.safe_parse_json(run.attrs_json, {})
    h_cmd = effective_command_json(run, h_cmd, h_attrs)
    command = build_inner_command(h_cmd)
    docker = docker_fields(run, h_env, h_cmd)

    {
      'step_label' => step_label(step, run),
      'step_description' => step_description(step, std_method),
      'step_category' => step_category(step),
      'method' => method_name(std_method, h_cmd),
      'command' => command,
      'software_version' => docker[:image_tag],
      'programming_language' => programming_language(h_cmd),
      'programming_language_version' => programming_language_version(run, h_cmd),
      'docker_repo' => docker[:repo],
      'docker_image_url' => docker[:image_url],
      'docker_image_name' => docker[:image_name],
      'docker_image_digest' => docker[:image_digest],
      'conda_env_url' => nil,
      'conda_env_file' => nil,
      'parameters' => command ? build_parameters(h_cmd, h_attrs) : nil,
      'inputs' => command ? build_inputs(run, h_cmd, h_attrs) : nil,
      'outputs' => command ? build_outputs(run) : nil,
      'resources' => build_resources(run),
      'execution_timestamp' => run.start_time&.utc&.strftime('%Y-%m-%dT%H:%M:%SZ'),
      'execution_duration_seconds' => run.duration&.to_f,
      'random_seed' => extract_seed(h_attrs, h_cmd)
    }
  end

  def step_label(step, run)
    base = step&.label.presence || step&.name.presence || "run_#{run.id}"
    "#{base} [#{run.id}]"
  end

  def step_description(step, std_method)
    std_method&.description.presence || step&.description.presence
  end

  def step_category(step)
    name = step&.name.to_s
    STEP_CATEGORY_BY_NAME[name] || 'Other'
  end

  def method_name(std_method, h_cmd)
    program = h_cmd['program'].to_s
    return 'parse.v8.py' if program.include?('parse.v8.py')
    return std_method.command_program if std_method&.command_program.present?
    return std_method.label.presence || std_method.name if std_method

    program.presence || 'Unknown'
  end

  # Prefer the command that actually ran in asap_run over the SLURM rails wrapper.
  def effective_command_json(run, h_cmd, h_attrs)
    return h_cmd unless h_cmd.is_a?(Hash)
    return h_cmd unless rails_parse_wrapper?(h_cmd)
    return h_cmd unless run.step&.name.to_s == 'parsing'
    return h_cmd if @project.version_id.to_i < 8

    reconstruct_v8_parse_command(h_attrs)
  end

  def rails_parse_wrapper?(h_cmd)
    h_cmd['program'].to_s.match?(/\Arails\s+parse\[/i)
  end

  # Rebuild python3 parse.v8.py for older runs that only stored rails parse[...].
  def reconstruct_v8_parse_command(h_attrs)
    parsing_attrs = Basic.safe_parse_json(@project.parsing_attrs_json, {})
    parsing_attrs = {} unless parsing_attrs.is_a?(Hash)
    attrs = parsing_attrs.merge(h_attrs.is_a?(Hash) ? h_attrs : {})

    file_type = attrs['file_type'].presence || attrs[:file_type].presence
    opts = []

    sel_name = attrs['sel_name'] || attrs['sel']
    if file_type.to_s.upcase == 'H5AD' && sel_name.present? && !sel_name.to_s.start_with?('/')
      sel_name = (sel_name.to_s == 'X') ? '/X' : "/layers/#{sel_name}"
    end
    opts << { 'opt' => '--sel', 'value' => sel_name } if sel_name.present?

    if file_type.to_s.upcase == 'RAW_TEXT'
      gene_name_col = attrs['gene_name_col'].presence || 'first'
      has_header = attrs['has_header']
      header_value = (has_header == '1' || has_header == true || has_header.to_s == 'true') ? 'true' : 'false'
      opts << { 'opt' => '--col', 'value' => gene_name_col }
      opts << { 'opt' => '--header', 'value' => header_value }
    end

    delim = attrs['delimiter']
    opts << { 'opt' => '--delim', 'value' => delim } if delim.present?

    input_file = resolve_parsing_upload_location || @project.input_filename
    opts += [
      { 'opt' => '--organism', 'value' => @project.organism_id },
      { 'opt' => '--filetype', 'value' => file_type },
      { 'opt' => '-o', 'value' => 'parsing' },
      { 'opt' => '-f', 'value' => input_file }
    ].select { |e| e['value'].present? }

    {
      'program' => 'python3 parse.v8.py',
      'opts' => opts,
      'args' => []
    }
  end

  def build_inner_command(h_cmd)
    return nil unless h_cmd.is_a?(Hash)
    return nil if h_cmd['program'].blank?

    program = h_cmd['program'].to_s
    opt_parts = Array(h_cmd['opts']).filter_map do |entry|
      next unless entry.is_a?(Hash)

      opt = entry['opt']
      next if opt.blank?

      val = entry['value']
      if val.nil? || val.to_s.strip == ''
        opt.to_s
      else
        "#{opt} #{shell_quote(relativize_path_value(val))}"
      end
    end
    arg_parts = Array(h_cmd['args']).filter_map do |entry|
      next unless entry.is_a?(Hash)
      next if entry['value'].nil?

      shell_quote(relativize_path_value(entry['value']))
    end

    [program, opt_parts.join(' '), arg_parts.join(' ')].reject(&:blank?).join(' ')
  end

  def shell_quote(value)
    s = value.to_s
    return s unless s.match?(/['"<>\s|;]/)

    '"' + s.gsub(/["\\]/) { |c| "\\#{c}" } + '"'
  end

  def docker_fields(run, h_env, h_cmd)
    build = run.docker_build
    if build&.docker_image
      major_name = "#{build.docker_image.name}:#{build.docker_image.tag}"
      digest = build.digest
      return {
        image_name: major_name,
        image_tag: build.docker_image.tag,
        image_url: build.dockerhub_layers_url,
        image_digest: digest,
        repo: 'dockerhub'
      }
    end

    image_name = docker_image_name_for(run, h_env, h_cmd)
    tag = image_name.to_s.split(':', 2).last
    tag = nil if tag.blank? || tag == image_name
    digest = docker_image_digest_fallback(image_name, run)
    {
      image_name: image_name,
      image_tag: tag,
      image_url: image_name.present? ? Basic.dockerhub_layers_url(image_name, digest: digest) : nil,
      image_digest: digest,
      repo: image_name.present? ? 'dockerhub' : nil
    }
  end

  # Older runs have no docker_build_id: fall back to catalog docker_images.digest
  # for analysis_pipeline display only (not written onto runs).
  def docker_image_digest_fallback(image_name, run)
    di = run.std_method&.docker_image || run.step&.docker_image
    return di.digest if di&.digest.present?

    name, tag = image_name.to_s.split(':', 2)
    return nil if name.blank? || tag.blank?

    DockerImage.find_by(name: name, tag: tag)&.digest
  end

  # ASAP runs always use the major catalog tag (v8, not v8.1). Prefer step/std_method
  # / env over scraping docker_call (which also contains --entrypoint '/bin/sh').
  def docker_image_name_for(run, h_env, h_cmd)
    di = run.std_method&.docker_image || run.step&.docker_image
    return di.full_name if di&.full_name.present?
    return "#{di.name}:#{di.tag}" if di&.name.present? && di&.tag.present?

    asap = h_env.dig('docker_images', 'asap_run')
    if asap.is_a?(Hash) && asap['name'].present? && asap['tag'].present?
      return "#{asap['name']}:#{asap['tag']}"
    end

    docker_call = h_cmd['docker_call'].to_s
    # Match user/repo:vN (major tag). Avoid false positives like bin/sh from --entrypoint.
    if (m = docker_call.match(%r{(?<![./\w-])([a-z0-9][a-z0-9_.-]*/[a-z0-9][a-z0-9_.-]+:v\d+)(?![.\w-])}i))
      return m[1]
    end

    nil
  end

  def programming_language(h_cmd)
    program = h_cmd['program'].to_s.downcase
    return 'Python' if program.include?('python') || program.end_with?('.py')
    return 'R' if program.include?('rscript') || program.match?(/\br\b/) || program.end_with?('.r')
    return 'Java' if program.include?('java') || program.end_with?('.jar')
    return 'Ruby' if program.include?('rails') || program.include?('ruby')
    return 'Bash' if program.include?('bash') || program.start_with?('sh ')

    nil
  end

  def programming_language_version(run, h_cmd)
    language = programming_language(h_cmd)
    return nil if language.blank?

    tools = docker_image_tools(run)
    return nil unless tools.is_a?(Hash)

    case language
    when 'Python' then tools['python3'].presence || tools['python'].presence
    when 'R' then tools['r'].presence
    when 'Java' then tools['java'].presence
    when 'Ruby' then tools['ruby'].presence
    when 'Bash' then tools['bash'].presence
    end
  end

  def docker_image_tools(run)
    di = docker_image_for(run)
    return {} unless di&.tools_json.present?

    Basic.safe_parse_json(di.tools_json, {})
  end

  def docker_image_for(run)
    run.docker_build&.docker_image || run.std_method&.docker_image || run.step&.docker_image
  end

  def build_parameters(h_cmd, h_attrs)
    params = []
    seen = {}

    Array(h_cmd['opts']).each do |entry|
      next unless entry.is_a?(Hash)

      name = entry['param_key'].presence || entry['opt']
      next if name.blank?
      next if seen[name]

      seen[name] = true
      value = relativize_path_value(entry['value'])
      params << {
        'name' => name.to_s,
        'value' => coerce_json_value(value),
        'type' => value_type(value),
        'description' => nil
      }
    end

    h_attrs.each do |key, value|
      next if seen[key]

      seen[key] = true
      value = relativize_path_value(value)
      params << {
        'name' => key.to_s,
        'value' => coerce_json_value(value),
        'type' => value_type(value),
        'description' => nil
      }
    end

    params
  end

  def build_inputs(run, h_cmd, h_attrs)
    inputs = []

    Array(h_cmd['opts']).each do |entry|
      next unless entry.is_a?(Hash)

      value = entry['value']
      location = filesystem_location_from_value(value)
      next if location.blank?

      location = relativize_path(location)
      param_key = entry['param_key'].to_s
      opt = entry['opt'].to_s
      next unless file_like_input?(param_key, opt, location)

      push_input!(inputs, label: param_key.presence || opt.presence || File.basename(location), location: location)
    end

    %w[input_matrix input_matrix_filename loom_filename groups_filename].each do |key|
      value = h_attrs[key]
      location = filesystem_location_from_value(value)
      next if location.blank?

      location = relativize_path(location)
      push_input!(inputs, label: key, location: location)
    end

    append_parsing_or_integration_inputs!(inputs, run, h_attrs)
    inputs
  end

  def append_parsing_or_integration_inputs!(inputs, run, h_attrs)
    return unless run.step&.name.to_s == 'parsing'

    if integration_run?(run, h_attrs)
      append_integration_source_inputs!(inputs, h_attrs)
    else
      append_upload_input_files!(inputs)
    end
  end

  def integration_run?(run, h_attrs)
    run.std_method&.name.to_s == 'integration' || Basic.integration_project?(h_attrs)
  end

  # Project upload consumed by parsing: projects.input_filename when present,
  # otherwise the durable Fu path under fus/<id>/.
  def append_upload_input_files!(inputs)
    location = resolve_parsing_upload_location
    if location.present?
      push_input!(
        inputs,
        label: 'input_filename',
        location: location,
        description: 'Uploaded input file used by parsing'
      )
    end

    return if @project.group_filename.blank?

    push_input!(
      inputs,
      label: 'group_filename',
      location: relativize_path(@project.group_filename),
      description: 'Group file used by parsing'
    )
  end

  def resolve_parsing_upload_location
    fu = Fu.resolve_for_project(@project)
    upload_dir = fu&.id ? fu.upload_dir_for_project(@project) : nil

    if upload_dir && ProjectInputFinalizerService.mtx_preparsed_bundle_dir?(upload_dir)
      return "fus/#{fu.id}/input_file"
    end

    return relativize_path(@project.input_filename) if @project.input_filename.present?
    return nil unless fu&.id && fu.upload_file_name.present?

    "fus/#{fu.id}/#{fu.upload_file_name}"
  end

  # Integration consumes parsing/output.loom from each source project.
  def append_integration_source_inputs!(inputs, h_attrs)
    Basic.integration_source_keys(h_attrs).each do |source_key|
      source = Project.find_by(key: source_key)
      next unless source&.user_id.present? && source.key.present?

      source_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + source.user_id.to_s + source.key
      location = (source_dir + 'parsing' + 'output.loom').to_s
      push_input!(
        inputs,
        label: "integrate_source:#{source_key}",
        location: location,
        description: "Source project #{source_key} loom used by integration"
      )
    end
  end

  def push_input!(inputs, label:, location:, description: nil)
    return if location.blank?
    return if inputs.any? { |i| i['location'] == location }

    inputs << {
      'label' => label.to_s,
      'type' => metadata_key?(location) ? 'metadata_key' : 'file',
      'format' => file_format(location),
      'location' => location,
      'description' => description,
      'checksum' => nil
    }
  end

  def build_outputs(run)
    outputs = []
    h_outputs = Basic.safe_parse_json(run.output_json, {})
    return outputs unless h_outputs.is_a?(Hash)

    h_outputs.each do |output_key, by_path|
      next unless by_path.is_a?(Hash)

      by_path.each do |path_key, meta|
        next unless meta.is_a?(Hash)

        file_part, dataset = path_key.to_s.split(':', 2)
        if dataset.present?
          location = dataset
          location_type = 'metadata_key'
        else
          location = relativize_path(file_part)
          location_type = 'file'
        end
        outputs << {
          'label' => output_key.to_s,
          'type' => location_type,
          'format' => file_format(file_part),
          'location' => location,
          'description' => meta['filename'].present? ? "filename=#{meta['filename']}" : nil,
          'checksum' => nil
        }
      end
    end

    outputs
  end

  def build_resources(run)
    {
      'cpu' => run.nber_cores.presence || 1,
      'memory_gb' => run.max_ram_gb,
      'gpu' => 0,
      'gpu_model' => nil
    }
  end

  def extract_seed(h_attrs, h_cmd)
    SEED_ATTR_KEYS.each do |key|
      return h_attrs[key].to_i if h_attrs.key?(key) && h_attrs[key].to_s =~ /\A-?\d+\z/
    end

    Array(h_cmd['opts']).each do |entry|
      next unless entry.is_a?(Hash)

      name = (entry['param_key'] || entry['opt']).to_s.downcase
      next unless SEED_ATTR_KEYS.any? { |k| name.include?(k) }
      next unless entry['value'].to_s =~ /\A-?\d+\z/

      return entry['value'].to_i
    end

    nil
  end

  def file_like_input?(param_key, opt, location)
    return true if metadata_key?(location)
    return true if location.match?(/\.(loom|h5ad|h5|rds|csv|tsv|txt|mtx|json|bam|fastq)(\.gz)?\z/i)
    return true if param_key.match?(/filename|filepath|loom|matrix|dataset|input|output/i)
    return true if opt.match?(/-f\z|--input|--loom|--matrix|--dataset/i)

    false
  end

  def metadata_key?(location)
    location.to_s.start_with?('/') && (
      location.start_with?('/col_attrs/', '/row_attrs/', '/attrs/', '/layers/', '/matrix', '/obsm/', '/uns/')
    )
  end

  def file_format(location)
    ext = File.extname(location.to_s.sub(/\.gz\z/i, '')).delete('.').downcase
    return nil if ext.blank?

    ext
  end

  # Extract a filesystem or loom metadata path from a command/attrs value.
  def filesystem_location_from_value(value)
    case value
    when Hash
      nested = value['output_filename'] || value[:output_filename] ||
               value['output_dataset'] || value[:output_dataset] ||
               value['filename'] || value[:filename]
      filesystem_location_from_value(nested)
    when String, Numeric
      s = value.to_s.strip
      s.presence
    else
      nil
    end
  end

  # Relativize path-like string values; leave non-path values unchanged.
  def relativize_path_value(value)
    case value
    when Hash
      value.transform_values { |v| relativize_path_value(v) }
    when Array
      value.map { |v| relativize_path_value(v) }
    when String
      path_like_filesystem_string?(value) ? relativize_path(value) : value
    else
      value
    end
  end

  def path_like_filesystem_string?(value)
    s = value.to_s
    return false if s.blank? || metadata_key?(s)

    marker = project_path_marker
    s.start_with?('/') || s.start_with?('../') || (marker.present? && s.include?(marker))
  end

  def project_path_marker
    @project_path_marker ||= "/#{@project.user_id}/#{@project.key}/"
  end

  # Convert absolute host paths to paths relative to the project directory.
  # Uses /{user_id}/{project_key}/ as the stable boundary so paths still resolve
  # when USER_DATA_DIR differs across environments (e.g. /data/asap vs /data/asap2_test).
  def relativize_path(path)
    s = path.to_s.strip
    return s if s.blank? || metadata_key?(s)

    marker = project_path_marker
    if marker.present? && (idx = s.index(marker))
      return s[(idx + marker.length)..]
    end

    project_dir_s = @project_dir.to_s.chomp('/')
    return '.' if s == project_dir_s
    return s.delete_prefix("#{project_dir_s}/") if s.start_with?("#{project_dir_s}/")

    if !s.start_with?('/') && !s.start_with?('../')
      return s
    end

    begin
      rel = Pathname.new(s).cleanpath.relative_path_from(@project_dir.cleanpath).to_s
      return rel if rel == '.' || (rel != '..' && !rel.start_with?('../'))
    rescue ArgumentError
      # keep original when paths are on different roots
    end

    s
  end

  def coerce_json_value(value)
    return value if value.nil? || value.is_a?(Numeric) || value.is_a?(TrueClass) || value.is_a?(FalseClass) || value.is_a?(Array)
    return JSON.generate(value) if value.is_a?(Hash)

    s = value.to_s
    return s.to_i if s.match?(/\A-?\d+\z/)
    return s.to_f if s.match?(/\A-?\d+\.\d+\z/)
    return true if s == 'true'
    return false if s == 'false'

    s
  end

  def value_type(value)
    v = coerce_json_value(value)
    case v
    when Integer then 'integer'
    when Float then 'float'
    when TrueClass, FalseClass then 'boolean'
    when Array then 'array'
    else 'string'
    end
  end
end
