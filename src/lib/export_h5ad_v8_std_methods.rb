# frozen_string_literal: true

# Upserts the ASAP release v8 hidden export_h5ad step and loom_to_h5ad StdMethod.
# Converts a project Loom sibling to a persistent .h5ad via SLURM / asap_run / anndata.
module ExportH5adV8StdMethods
  VERSION_ID = 8
  STEP_NAME = 'export_h5ad'
  STD_METHOD_NAME = 'loom_to_h5ad'

  STEP_COMMAND_JSON = {
    'host_name' => 'localhost',
    'docker_image' => 'asap_run',
    'async' => true
  }.freeze

  STEP_OUTPUT_JSON = {
    'expected_outputs' => {
      'output_json' => {
        'types' => ['json_file'],
        'filename' => 'output.json',
        'never_empty' => true
      },
      'exec_stdout' => {
        'types' => ['log_file'],
        'filename' => 'exec.out'
      },
      'exec_stderr' => {
        'types' => ['log_file'],
        'filename' => 'exec.err'
      }
    }
  }.freeze

  METHOD_ATTRS_JSON = {
    'input_loom' => {
      'label' => 'Input Loom path',
      'description' => 'Project-relative path to the Loom file to convert (e.g. parsing/output.loom).',
      'widget' => 'text_field',
      'not_null' => true
    },
    'input_loom_abs' => {
      'label' => 'Input Loom absolute path',
      'description' => 'Absolute path filled at runtime.',
      'widget' => 'text_field',
      'not_null' => true
    },
    'output_h5ad_abs' => {
      'label' => 'Output H5AD absolute path',
      'description' => 'Absolute sibling .h5ad path filled at runtime.',
      'widget' => 'text_field',
      'not_null' => true
    }
  }.freeze

  STD_METHOD_COMMAND_JSON = {
    'program' => 'python loom_to_h5ad.v8.py',
    'opts' => [
      { 'opt' => '-i', 'param_key' => 'input_loom_abs' },
      { 'opt' => '-o', 'param_key' => 'output_h5ad_abs' },
      { 'opt' => '-d', 'param_key' => 'output_dir' }
    ],
    'predict_params' => []
  }.freeze

  class << self
    def upsert!(version_id: VERSION_ID, docker_image_id: nil)
      docker_image = resolve_docker_image!(version_id, docker_image_id)
      speed = Speed.find_by(id: 1) || Speed.first
      raise 'No Speed row found' unless speed

      step = ensure_step!(version_id, docker_image)

      summary = { created: [], updated: [], unchanged: [] }

      defn = { name: STD_METHOD_NAME }
      attrs = build_std_method_attrs(defn, step: step, docker_image: docker_image, speed: speed)
      record = StdMethod.find_by(name: defn[:name], step_id: step.id, version_id: version_id)

      if record.nil?
        StdMethod.create!(attrs)
        summary[:created] << defn[:name]
      elsif std_method_changed?(record, attrs)
        record.update!(attrs)
        summary[:updated] << defn[:name]
      else
        summary[:unchanged] << defn[:name]
      end

      summary[:step_id] = step.id
      summary
    end

    private

    def resolve_docker_image!(version_id, docker_image_id)
      return DockerImage.find(docker_image_id) if docker_image_id.present?

      version = Version.find_by(id: version_id)
      raise "Version #{version_id} not found" unless version

      image = Basic.get_asap_docker(version)
      image ||= DockerImage.find_by(tag: "v#{version_id}")
      image ||= DockerImage.where(version_id: version_id).order(:id).first
      raise "No DockerImage found for version_id=#{version_id}" unless image

      image
    end

    def ensure_step!(version_id, docker_image)
      step = Step.find_by(name: STEP_NAME, version_id: version_id, docker_image_id: docker_image.id)
      step ||= Step.new(name: STEP_NAME, version_id: version_id, docker_image_id: docker_image.id)

      if step.new_record?
        reference = reference_step(version_id, docker_image.id)
        step.rank = ((reference&.rank) || Step.where(version_id: version_id, docker_image_id: docker_image.id).maximum(:rank).to_i) + 1
        step.group_name = reference&.group_name
        step.color = reference&.color
      end

      step.name = STEP_NAME
      step.obj_name = STEP_NAME if step.respond_to?(:obj_name=)
      step.label = 'Export H5AD'
      step.tag = 'export_h5ad'
      step.description = 'Convert a project Loom file to a persistent H5AD (AnnData) export via sceasy.'
      step.multiple_runs = true
      step.is_std_step = true
      step.has_std_form = false
      step.has_std_view = false
      step.hidden = true
      step.admin = false
      step.method_attrs_json = JSON.pretty_generate(METHOD_ATTRS_JSON)
      step.command_json = JSON.pretty_generate(STEP_COMMAND_JSON)
      step.output_json = JSON.pretty_generate(STEP_OUTPUT_JSON)
      step.show_view_json = '[]'
      step.attrs_json = { 'project_types' => [] }.to_json
      step.save!
      step
    end

    def reference_step(version_id, docker_image_id)
      %w[markers module_score import_metadata].each do |name|
        s = Step.find_by(name: name, version_id: version_id, docker_image_id: docker_image_id)
        return s if s
      end
      nil
    end

    def build_std_method_attrs(defn, step:, docker_image:, speed:)
      {
        name: defn[:name],
        label: 'Loom to H5AD',
        short_label: 'h5ad',
        description: 'Convert Loom to AnnData H5AD with anndata (NumPy 2-compatible).',
        link: '',
        version_id: step.version_id,
        docker_image_id: docker_image.id,
        step_id: step.id,
        speed_id: speed.id,
        nber_cores: 1,
        obsolete: false,
        attrs_json: '{}',
        attr_layout_json: '[]',
        obj_attrs_json: { project_types: [], handles_log: false }.to_json,
        command_json: JSON.pretty_generate(STD_METHOD_COMMAND_JSON),
        output_json: JSON.pretty_generate(STEP_OUTPUT_JSON)
      }
    end

    def std_method_changed?(record, attrs)
      %i[label description link speed_id command_json output_json attrs_json attr_layout_json obj_attrs_json
         short_label obsolete].any? do |key|
        record.public_send(key).to_s != attrs[key].to_s
      end
    end
  end
end
