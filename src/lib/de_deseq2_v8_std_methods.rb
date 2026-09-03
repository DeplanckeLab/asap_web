# frozen_string_literal: true

# Aligns v8 DESeq2 StdMethod command_json with de.v8.py CLI.
#
# Legacy deseq2 opts used --output-dataset / --group1 / --group2 (and /row_attrs/
# metadata paths). de.v8.py expects --write-metadata / --group / --group-2 and
# /attrs/ paths (same as wilcoxon / t_test). Also wires --batch to covariates.
module DeDeseq2V8StdMethods
  VERSION_ID = 8
  STEP_NAME = 'de'
  STD_METHOD_NAME = 'deseq2'

  PROGRAM_FRAGMENTS = %w[de.v8.py].freeze

  STD_METHOD_COMMAND_JSON = {
    # -u: ErrorJSON uses print + os._exit; without unbuffered stdout the message never
    # reaches exec.out when redirected, and the UI only shows a generic exit status.
    'program' => 'python -u de.v8.py',
    'opts' => [
      { 'opt' => '-f', 'param_key' => 'input_matrix_filename' },
      { 'opt' => '-o', 'param_key' => 'output_dir' },
      { 'opt' => '--method', 'param_key' => 'std_method_name' },
      { 'opt' => '--input-dataset', 'param_key' => 'input_matrix_dataset' },
      {
        'opt' => '--write-metadata',
        'param_key' => 'output_mdata',
        'value' => '/attrs/_#{step_tag}_#{run_num}_#{std_method_name}'
      },
      { 'opt' => '--write-volcano', 'param_key' => 'write_volcano' },
      { 'opt' => '--batch', 'param_key' => 'covariates', 'omit_when_null' => true },
      { 'opt' => '--group-dataset', 'param_key' => 'groups_dataset' },
      { 'opt' => '--group', 'param_key' => 'group_ref', 'null_value' => 'null' },
      { 'opt' => '--group-dataset-2', 'param_key' => 'groups2_dataset', 'omit_when_null' => true },
      { 'opt' => '--group-2', 'param_key' => 'group_comp', 'null_value' => 'null' },
      { 'opt' => '--is-count', 'param_key' => 'is_count_table', 'value' => '#{input_matrix_is_count_table}' },
      { 'opt' => '--preview-cell-fraction', 'param_key' => 'preview_cell_fraction', 'omit_when_null' => true },
      { 'opt' => '--preview-max-cells', 'param_key' => 'preview_max_cells', 'omit_when_null' => true },
      { 'opt' => '--cell-universe-file', 'param_key' => 'cell_universe_file', 'omit_when_null' => true },
      { 'opt' => '--cell-universe-mode', 'param_key' => 'cell_universe_mode', 'omit_when_null' => true }
    ],
    'predict_params' => %w[nber_cols nber_rows std_method_name preview_cell_fraction preview_max_cells]
  }.freeze

  class << self
    def upsert!(version_id: VERSION_ID, docker_image_id: nil)
      docker_image = resolve_docker_image!(version_id, docker_image_id)
      step = Step.find_by!(docker_image_id: docker_image.id, name: STEP_NAME)
      summary = { updated: [], unchanged: [], skipped: [] }

      StdMethod.where(docker_image_id: docker_image.id, step_id: step.id, name: STD_METHOD_NAME).find_each do |sm|
        raw = sm.command_json.to_s.strip
        if raw.empty?
          summary[:skipped] << "std_method:#{sm.name}##{sm.id} (empty command_json)"
          next
        end

        cmd = Basic.safe_parse_json(raw, {})
        program = cmd['program'].to_s
        unless PROGRAM_FRAGMENTS.any? { |frag| program.include?(frag) }
          summary[:skipped] << "std_method:#{sm.name}##{sm.id} (program=#{program.inspect})"
          next
        end

        if update_record!(sm, command_json: JSON.pretty_generate(STD_METHOD_COMMAND_JSON))
          summary[:updated] << "std_method:#{sm.name}##{sm.id}"
        else
          summary[:unchanged] << "std_method:#{sm.name}##{sm.id}"
        end
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
        current = record.public_send(key)
        next if normalize_json_text(current.to_s) == normalize_json_text(value.to_s)

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
