# frozen_string_literal: true

# Adds preview_cell_fraction / preview_max_cells to DE StdMethods that run
# de_approx.v8.py (the Python CLI that implements --preview-cell-fraction).
#
# predict_params includes those keys so Basic.apply_preview_to_predict_nber_cols
# scales nber_cols for RAM/time prediction when the user sets a fraction.
module DePreviewV8StdMethods
  VERSION_ID = 8
  STEP_NAME = 'de'

  PREVIEW_PROGRAM_FRAGMENTS = %w[de_approx.v8.py de.v8.py].freeze


  PREVIEW_CELL_FRACTION_OPT = {
    'opt' => '--preview-cell-fraction',
    'param_key' => 'preview_cell_fraction',
    'omit_when_null' => true
  }.freeze

  PREVIEW_MAX_CELLS_OPT = {
    'opt' => '--preview-max-cells',
    'param_key' => 'preview_max_cells',
    'omit_when_null' => true
  }.freeze

  PREVIEW_ATTRS = {
    'preview_cell_fraction' => {
      'label' => 'Preview cell fraction',
      'widget' => 'textfield',
      'type' => 'float',
      'optional' => true,
      'default' => nil,
      'description' =>
        'Optional. When set to a value in (0, 1], randomly subsample about this fraction of cells ' \
        'per category before DE (approximate, lower RAM/time). Leave empty for all cells.',
      'trigger_upd_pred' => true
    },
    'preview_max_cells' => {
      'label' => 'Preview max cells',
      'widget' => 'textfield',
      'type' => 'integer',
      'optional' => true,
      'default' => 10_000,
      'description' =>
        'Per-stratum cap used with preview cell fraction (default 10000). Ignored when preview ' \
        'cell fraction is empty.',
      'trigger_upd_pred' => true
    }
  }.freeze

  PREDICT_PREVIEW_KEYS = %w[preview_cell_fraction preview_max_cells].freeze

  class << self
    def upsert!(version_id: VERSION_ID, docker_image_id: nil)
      docker_image = resolve_docker_image!(version_id, docker_image_id)
      step = Step.find_by!(docker_image_id: docker_image.id, name: STEP_NAME)
      summary = { updated: [], unchanged: [], skipped: [] }

      StdMethod.where(docker_image_id: docker_image.id, step_id: step.id).find_each do |sm|
        cmd = Basic.safe_parse_json(sm.command_json, {})
        program = cmd['program'].to_s
        unless PREVIEW_PROGRAM_FRAGMENTS.any? { |frag| program.include?(frag) }
          summary[:skipped] << "std_method:#{sm.name}##{sm.id} (program=#{program.inspect})"
          next
        end

        attrs = Basic.safe_parse_json(sm.attrs_json, {})
        attrs = {} unless attrs.is_a?(Hash)
        PREVIEW_ATTRS.each do |k, v|
          attrs[k] = v
        end

        opts = Array(cmd['opts']).map(&:dup)
        ensure_opt!(opts, PREVIEW_CELL_FRACTION_OPT)
        ensure_opt!(opts, PREVIEW_MAX_CELLS_OPT)
        cmd['opts'] = opts

        predict = Array(cmd['predict_params']).map(&:to_s)
        predict = %w[nber_cols nber_rows std_method_name] if predict.empty?
        PREDICT_PREVIEW_KEYS.each do |k|
          predict << k unless predict.include?(k)
        end
        cmd['predict_params'] = predict

        if update_record!(sm, command_json: JSON.pretty_generate(cmd), attrs_json: JSON.pretty_generate(attrs))
          summary[:updated] << "std_method:#{sm.name}##{sm.id}"
        else
          summary[:unchanged] << "std_method:#{sm.name}##{sm.id}"
        end
      end

      summary
    end

    private

    def ensure_opt!(opts, desired)
      idx = opts.index { |o| o.is_a?(Hash) && o['opt'].to_s == desired['opt'] }
      if idx
        opts[idx] = desired.dup
      else
        opts << desired.dup
      end
    end

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
