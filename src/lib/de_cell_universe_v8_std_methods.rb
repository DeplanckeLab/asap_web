# frozen_string_literal: true

# Adds optional cell-universe CLI opts to DE StdMethods that run de.v8.py / de_approx.v8.py.
# Attrs cell_universe_file / cell_universe_mode are staged by the viz before DE submit.
module DeCellUniverseV8StdMethods
  VERSION_ID = 8
  STEP_NAME = 'de'

  PROGRAM_FRAGMENTS = %w[de_approx.v8.py de.v8.py].freeze

  CELL_UNIVERSE_FILE_OPT = {
    'opt' => '--cell-universe-file',
    'param_key' => 'cell_universe_file',
    'omit_when_null' => true
  }.freeze

  CELL_UNIVERSE_MODE_OPT = {
    'opt' => '--cell-universe-mode',
    'param_key' => 'cell_universe_mode',
    'omit_when_null' => true
  }.freeze

  class << self
    def upsert!(version_id: VERSION_ID, docker_image_id: nil)
      docker_image = resolve_docker_image!(version_id, docker_image_id)
      step = Step.find_by!(docker_image_id: docker_image.id, name: STEP_NAME)
      summary = { updated: [], unchanged: [], skipped: [] }

      StdMethod.where(docker_image_id: docker_image.id, step_id: step.id).find_each do |sm|
        cmd = Basic.safe_parse_json(sm.command_json, {})
        program = cmd['program'].to_s
        unless PROGRAM_FRAGMENTS.any? { |frag| program.include?(frag) }
          summary[:skipped] << "std_method:#{sm.name}##{sm.id} (program=#{program.inspect})"
          next
        end

        opts = Array(cmd['opts']).map(&:dup)
        ensure_opt!(opts, CELL_UNIVERSE_FILE_OPT)
        ensure_opt!(opts, CELL_UNIVERSE_MODE_OPT)
        cmd['opts'] = opts

        if update_record!(sm, command_json: JSON.pretty_generate(cmd))
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
