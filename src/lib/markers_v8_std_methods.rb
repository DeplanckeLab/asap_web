# frozen_string_literal: true

# Upserts the ASAP release v8 markers step and asap_markers StdMethod.
#
# v8+ Identify markers uses de.v8.py FindAllMarkers (omit --group / --group-2)
# with --write-tsv so each category writes markers/<run_id>/cat_N.tsv.
# Older docker images keep the Java FindMarkers asap_markers StdMethod.
module MarkersV8StdMethods
  VERSION_ID = 8
  STEP_NAME = 'markers'
  STD_METHOD_NAME = 'asap_markers'

  STEP_COMMAND_JSON = {
    'host_name' => 'localhost',
    'docker_image' => 'asap_run',
    'program' => 'python de.v8.py',
    'async' => true
  }.freeze

  STD_METHOD_COMMAND_JSON = {
    'program' => 'python de.v8.py',
    'opts' => [
      { 'opt' => '-f', 'param_key' => 'groups_filename' },
      { 'opt' => '-o', 'param_key' => 'output_dir' },
      { 'opt' => '--method', 'value' => 'wilcoxon' },
      { 'opt' => '--input-dataset', 'param_key' => 'input_matrix_dataset' },
      { 'opt' => '--group-dataset', 'param_key' => 'groups_dataset' },
      { 'opt' => '--is-count', 'value' => '#{input_matrix_is_count_table}' },
      { 'opt' => '--write-tsv', 'value' => 'true', 'valueless_flag' => true }
    ],
    'predict_params' => %w[nber_cols nber_rows std_method_name nber_cats]
  }.freeze

  class << self
    def upsert!(version_id: VERSION_ID, docker_image_id: nil)
      docker_image = resolve_docker_image!(version_id, docker_image_id)
      step = Step.find_by!(docker_image_id: docker_image.id, name: STEP_NAME)
      std_method = StdMethod.find_by!(docker_image_id: docker_image.id, name: STD_METHOD_NAME)

      summary = { updated: [], unchanged: [], created: [] }

      step_attrs = {
        command_json: STEP_COMMAND_JSON.to_json
      }
      if update_record!(step, step_attrs)
        summary[:updated] << "step:#{STEP_NAME}##{step.id}"
      else
        summary[:unchanged] << "step:#{STEP_NAME}##{step.id}"
      end

      std_attrs = {
        command_json: STD_METHOD_COMMAND_JSON.to_json
      }
      if update_record!(std_method, std_attrs)
        summary[:updated] << "std_method:#{STD_METHOD_NAME}##{std_method.id}"
      else
        summary[:unchanged] << "std_method:#{STD_METHOD_NAME}##{std_method.id}"
      end

      summary
    end

    private

    def resolve_docker_image!(version_id, docker_image_id)
      if docker_image_id.present?
        return DockerImage.find(docker_image_id)
      end

      version = Version.find_by(id: version_id)
      raise "Version #{version_id} not found" unless version

      docker_image = Basic.get_asap_docker(version)
      raise "No asap_run DockerImage for version #{version_id}" unless docker_image

      docker_image
    end

    def update_record!(record, attrs)
      changed = false
      attrs.each do |key, value|
        current = record.public_send(key).to_s
        next if normalize_json_text(current) == normalize_json_text(value.to_s)

        record.public_send("#{key}=", value)
        changed = true
      end
      record.save! if changed
      changed
    end

    def normalize_json_text(text)
      parsed = JSON.parse(text)
      JSON.generate(parsed)
    rescue JSON::ParserError
      text.to_s.strip
    end
  end
end
