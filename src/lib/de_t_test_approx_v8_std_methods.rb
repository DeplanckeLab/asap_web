# frozen_string_literal: true

require_relative 'de_preview_v8_std_methods'

# Upserts the v8 DE StdMethod t_test_approx (de_approx.v8.py Welch; streams large looms).
#
# Large DE inputs (>= Basic::DE_LARGE_DATASET_MIN_CELLS cells) should only run this method.
module DeTTestApproxV8StdMethods
  VERSION_ID = 8
  STEP_NAME = 'de'
  STD_METHOD_NAME = 't_test_approx'

  STD_METHOD_COMMAND_JSON = {
    'program' => 'python de_approx.v8.py',
    'opts' => [
      { 'opt' => '-f', 'param_key' => 'input_matrix_filename' },
      { 'opt' => '-o', 'param_key' => 'output_dir' },
      { 'opt' => '--method', 'value' => 't_test_approx' },
      { 'opt' => '--input-dataset', 'param_key' => 'input_matrix_dataset' },
      {
        'opt' => '--write-metadata',
        'param_key' => 'output_mdata',
        'value' => '/attrs/_#{step_tag}_#{run_num}_#{std_method_name}'
      },
      { 'opt' => '--write-volcano', 'param_key' => 'write_volcano' },
      { 'opt' => '--group-dataset', 'param_key' => 'groups_dataset' },
      { 'opt' => '--group', 'param_key' => 'group_ref', 'null_value' => 'null' },
      { 'opt' => '--group-dataset-2', 'param_key' => 'groups_dataset', 'omit_when_param_blank' => 'group_comp' },
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
      template = StdMethod.find_by(docker_image_id: docker_image.id, step_id: step.id, name: 't_test')

      std_method = StdMethod.find_or_initialize_by(
        docker_image_id: docker_image.id,
        step_id: step.id,
        name: STD_METHOD_NAME
      )
      created = std_method.new_record?

      attrs = {
        label: 'Approximate t-test (Welch)',
        short_label: 't-test approx',
        description:
          'Welch t-test per gene with Benjamini–Hochberg FDR. Streams large dense looms via a ' \
          'gene-chunked cache (scalable). Prefer this method for datasets with many cells.',
        link: template&.link.to_s,
        speed_id: template&.speed_id || 3,
        command_json: JSON.pretty_generate(STD_METHOD_COMMAND_JSON),
        attrs_json: JSON.pretty_generate(DePreviewV8StdMethods::PREVIEW_ATTRS.deep_dup),
        obj_attrs_json: template&.obj_attrs_json.presence || '{}',
        attr_layout_json: template&.attr_layout_json.presence || '[]',
        obsolete: false
      }
      if template&.respond_to?(:version_id) && template.version_id.present?
        attrs[:version_id] = template.version_id
      end

      changed = apply_attrs!(std_method, attrs)
      summary = { updated: [], unchanged: [], created: [] }
      if created
        summary[:created] << "std_method:#{STD_METHOD_NAME}##{std_method.id}"
      elsif changed
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

    def apply_attrs!(record, attrs)
      changed = false
      attrs.each do |key, value|
        next unless record.respond_to?("#{key}=")

        current = record.public_send(key)
        if key.to_s.end_with?('_json')
          next if normalize_json_text(current.to_s) == normalize_json_text(value.to_s)
        else
          next if current == value
        end

        record.public_send("#{key}=", value)
        changed = true
      end
      record.save! if changed || record.new_record?
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
