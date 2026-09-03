# frozen_string_literal: true

# Ensure v8 DE Python CLIs run with unbuffered stdout (python -u).
#
# de.v8.py ErrorJSON does print(...) then os._exit(1). With stdout redirected to
# exec.out, block buffering drops the JSON and the UI only shows a generic
# "non-zero status" message.
module DePythonUnbufferedV8StdMethods
  VERSION_ID = 8
  STEP_NAME = 'de'
  PROGRAM_FRAGMENTS = %w[de.v8.py de_approx.v8.py].freeze

  class << self
    def upsert!(version_id: VERSION_ID, docker_image_id: nil)
      docker_image = resolve_docker_image!(version_id, docker_image_id)
      step = Step.find_by!(docker_image_id: docker_image.id, name: STEP_NAME)
      summary = { updated: [], unchanged: [], skipped: [] }

      StdMethod.where(docker_image_id: docker_image.id, step_id: step.id).find_each do |sm|
        raw = sm.command_json.to_s.strip
        if raw.empty?
          summary[:skipped] << "std_method:#{sm.name}##{sm.id} (empty command_json)"
          next
        end

        cmd = Basic.safe_parse_json(raw, {})
        program = cmd['program'].to_s.strip
        unless PROGRAM_FRAGMENTS.any? { |frag| program.include?(frag) }
          summary[:skipped] << "std_method:#{sm.name}##{sm.id} (program=#{program.inspect})"
          next
        end

        new_program = unbuffered_program(program)
        if new_program == program
          summary[:unchanged] << "std_method:#{sm.name}##{sm.id}"
          next
        end

        cmd['program'] = new_program
        if update_record!(sm, command_json: JSON.pretty_generate(cmd))
          summary[:updated] << "std_method:#{sm.name}##{sm.id}"
        else
          summary[:unchanged] << "std_method:#{sm.name}##{sm.id}"
        end
      end

      summary
    end

    def unbuffered_program(program)
      return program if program.match?(/\Apython\s+-u\b/)

      program.sub(/\Apython\b/, 'python -u')
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
