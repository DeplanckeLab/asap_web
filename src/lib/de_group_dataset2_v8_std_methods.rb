# frozen_string_literal: true

# Fixes DE Step / StdMethod CLI wiring for a second grouping column:
#   --group-dataset-2 must use param_key groups2_dataset (omit when blank).
# Also renames the mistyped Step opt --group-dataset2 -> --group-dataset-2.
#
# Same-metadata comparisons omit --group-dataset-2; de.v8.py then uses --group-dataset
# for both sides. Second-metadata mode sets groups2_dataset from attrs["groups2"].
module DeGroupDataset2V8StdMethods
  VERSION_ID = 8
  STEP_NAME = 'de'

  PROGRAM_FRAGMENTS = %w[de_approx.v8.py de.v8.py].freeze

  LEGACY_OPT_NAMES = %w[--group-dataset2 --group-dataset-2].freeze

  GROUP_DATASET_2_OPT = {
    'opt' => '--group-dataset-2',
    'param_key' => 'groups2_dataset',
    'omit_when_null' => true
  }.freeze

  class << self
    def upsert!(version_id: VERSION_ID, docker_image_id: nil)
      docker_image = resolve_docker_image!(version_id, docker_image_id)
      step = Step.find_by!(docker_image_id: docker_image.id, name: STEP_NAME)
      summary = { step: nil, updated: [], unchanged: [], skipped: [] }

      summary[:step] = patch_step!(step)

      StdMethod.where(docker_image_id: docker_image.id, step_id: step.id).find_each do |sm|
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

        opts = Array(cmd['opts']).map { |o| o.is_a?(Hash) ? o.dup : o }
        patch_group_dataset_2_opts!(opts)
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

    def patch_step!(step)
      cmd = Basic.safe_parse_json(step.command_json, {})
      opts = Array(cmd['opts']).map { |o| o.is_a?(Hash) ? o.dup : o }
      patch_group_dataset_2_opts!(opts)
      cmd['opts'] = opts
      if update_record!(step, command_json: JSON.pretty_generate(cmd))
        "step:#{step.name}##{step.id} updated"
      else
        "step:#{step.name}##{step.id} unchanged"
      end
    end

    def patch_group_dataset_2_opts!(opts)
      opts.reject! do |o|
        o.is_a?(Hash) && LEGACY_OPT_NAMES.include?(o['opt'].to_s)
      end

      idx = opts.index { |o| o.is_a?(Hash) && o['opt'].to_s == GROUP_DATASET_2_OPT['opt'] }
      if idx
        opts[idx] = GROUP_DATASET_2_OPT.dup
      else
        insert_after = opts.index { |o| o.is_a?(Hash) && o['opt'].to_s == '--group' }
        if insert_after
          opts.insert(insert_after + 1, GROUP_DATASET_2_OPT.dup)
        else
          opts << GROUP_DATASET_2_OPT.dup
        end
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
