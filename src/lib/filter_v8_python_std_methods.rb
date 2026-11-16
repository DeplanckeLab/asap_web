# frozen_string_literal: true

require "json"

# Switches the v8 Step / StdMethod command_json rows that still run the legacy Java filtering
# modes (java -jar ASAP.jar -T FilterCols / -T FilterRows) to their Python port shipped in the
# asap_run:v8 image (/srv/filter.v8.py: same flags, same output.loom / output.json).
#
# Only "program" changes. filter.v8.py accepts the same -T / -loom / -o / -m / -row_names_file /
# -col_indexes_file / -col_names_file options, so opts and args are kept as they are. Commands
# running other ASAP.jar modes (ModuleScore, ExtractMetadata, ...) are left untouched.
#
# When a StdMethod gets its program from its Step (StdMethod command_json keys override Step keys,
# see Basic.set_run / ReqsController#create), the Python program is written on the StdMethod so
# that other methods sharing the Step program are not affected.
module FilterV8PythonStdMethods
  VERSION_ID = 8
  PYTHON_PROGRAM = "python3 /srv/filter.v8.py"
  FILTER_MODES = %w[FilterCols FilterRows].freeze
  # "java [JVM options] -jar [dir/]ASAP.jar"
  JAVA_ASAP_JAR_RE = %r{\A\s*(?:\S*/)?java(?:\s+(?!-jar(?:\s|\z))\S+)*\s+-jar\s+\S*ASAP\.jar(?=\s|\z)}
  MODE_IN_PROGRAM_RE = /(?:\A|\s)-T\s+(#{FILTER_MODES.join('|')})(?=\s|\z)/

  class << self
    # Python program replacing a "java ... -jar ASAP.jar" program (anything after the jar, e.g.
    # "-T FilterCols", is kept); nil when +program+ does not call ASAP.jar.
    def python_program_for(program)
      s = program.to_s
      return nil unless s.match?(JAVA_ASAP_JAR_RE)

      s.sub(JAVA_ASAP_JAR_RE, PYTHON_PROGRAM)
    end

    # FilterCols / FilterRows when the command runs one of them (-T in program or in opts), else nil.
    def filter_mode(h_cmd)
      return nil unless h_cmd.is_a?(Hash)

      m = h_cmd["program"].to_s.match(MODE_IN_PROGRAM_RE)
      return m[1] if m

      Array(h_cmd["opts"]).each do |opt|
        next unless opt.is_a?(Hash) && opt["opt"].to_s.strip == "-T"

        value = opt["value"].to_s.strip
        return value if FILTER_MODES.include?(value)
      end
      nil
    end

    def java_filter_command?(h_cmd)
      h_cmd.is_a?(Hash) && !python_program_for(h_cmd["program"]).nil? && !filter_mode(h_cmd).nil?
    end

    # New Step command hash, or nil when the Step command alone is not a Java filtering command.
    def rewritten_step_command(step_cmd)
      return nil unless java_filter_command?(step_cmd)

      step_cmd.merge("program" => python_program_for(step_cmd["program"]))
    end

    # New StdMethod command hash, or nil when the merged Step + StdMethod command is not a Java
    # filtering command. +step_cmd+ is the (already rewritten) Step command.
    def rewritten_method_command(step_cmd, method_cmd)
      step_cmd = {} unless step_cmd.is_a?(Hash)
      method_cmd = {} unless method_cmd.is_a?(Hash)
      merged = step_cmd.merge(method_cmd)
      return nil unless java_filter_command?(merged)

      program = python_program_for(merged["program"])
      if method_cmd.key?("program")
        method_cmd.merge("program" => program)
      else
        { "program" => program }.merge(method_cmd)
      end
    end

    # Rewrites the matching rows of +version_id+ (Steps of that version or of its ASAP docker image,
    # and their StdMethods). Returns { changes: [...], unchanged: n }; nothing is saved when dry_run.
    def apply!(version_id: VERSION_ID, docker_image_id: nil, dry_run: false)
      docker_image = resolve_docker_image(version_id, docker_image_id)
      scope = Step.where(version_id: version_id)
      scope = scope.or(Step.where(docker_image_id: docker_image.id)) if docker_image
      steps = scope.order(:id).to_a
      summary = { changes: [], unchanged: 0 }

      step_cmds = {}
      steps.each do |step|
        h_cmd = parse_command(step.command_json)
        new_cmd = rewritten_step_command(h_cmd)
        if new_cmd
          summary[:changes] << change_entry(step, filter_mode(h_cmd), h_cmd, new_cmd)
          step.update!(command_json: dump_like(step.command_json, new_cmd)) unless dry_run
          h_cmd = new_cmd
        end
        step_cmds[step.id] = h_cmd
      end

      StdMethod.where(step_id: step_cmds.keys).order(:id).each do |std_method|
        h_cmd = parse_command(std_method.command_json)
        new_cmd = rewritten_method_command(step_cmds[std_method.step_id], h_cmd)
        if new_cmd.nil? || new_cmd == h_cmd
          summary[:unchanged] += 1
          next
        end
        mode = filter_mode((step_cmds[std_method.step_id] || {}).merge(h_cmd))
        summary[:changes] << change_entry(std_method, mode, h_cmd, new_cmd)
        std_method.update!(command_json: dump_like(std_method.command_json, new_cmd)) unless dry_run
      end

      summary
    end

    private

    def parse_command(raw)
      h = raw.present? ? JSON.parse(raw) : {}
      h.is_a?(Hash) ? h : {}
    rescue JSON::ParserError
      {}
    end

    # Keep the row's layout: pretty JSON stays pretty, one-line JSON stays one line.
    def dump_like(raw, h_cmd)
      raw.to_s.include?("\n") ? JSON.pretty_generate(h_cmd) : JSON.generate(h_cmd)
    end

    def change_entry(record, mode, old_cmd, new_cmd)
      {
        model: record.class.name,
        id: record.id,
        name: record.name,
        mode: mode,
        from: old_cmd["program"],
        to: new_cmd["program"]
      }
    end

    def resolve_docker_image(version_id, docker_image_id)
      return DockerImage.find(docker_image_id) if docker_image_id.present?

      version = Version.find_by(id: version_id)
      version ? Basic.get_asap_docker(version) : nil
    end
  end
end
