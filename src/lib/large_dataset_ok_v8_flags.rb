# frozen_string_literal: true

# Marks v8 steps/methods that may run when the selected input matrix is at or above
# Basic.large_dataset_min_cells (ENV ASAP_LARGE_DATASET_MIN_CELLS).
#
# Step.attrs_json / StdMethod.obj_attrs_json key: Basic::LARGE_DATASET_OK_ATTR
module LargeDatasetOkV8Flags
  VERSION_ID = 8
  STEP_NAMES = %w[cell_filtering import_metadata].freeze
  STD_METHOD_SPECS = [
    { step_name: 'de', method_name: 't_test_approx' }
  ].freeze

  class << self
    def upsert!(version_id: VERSION_ID, docker_image_id: nil)
      docker_image = resolve_docker_image!(version_id, docker_image_id)
      summary = { updated: [], unchanged: [], missing: [] }

      STEP_NAMES.each do |step_name|
        step = Step.find_by(docker_image_id: docker_image.id, name: step_name)
        unless step
          summary[:missing] << "step:#{step_name}"
          next
        end

        attrs = Basic.safe_parse_json(step.attrs_json, {})
        if Basic.json_flag_true?(attrs[Basic::LARGE_DATASET_OK_ATTR])
          summary[:unchanged] << "step:#{step_name}##{step.id}"
          next
        end

        attrs = attrs.merge(Basic::LARGE_DATASET_OK_ATTR => true)
        step.update!(attrs_json: JSON.pretty_generate(attrs))
        summary[:updated] << "step:#{step_name}##{step.id}"
      end

      STD_METHOD_SPECS.each do |spec|
        step = Step.find_by(docker_image_id: docker_image.id, name: spec[:step_name])
        unless step
          summary[:missing] << "step:#{spec[:step_name]}"
          next
        end

        std_method = StdMethod.find_by(
          docker_image_id: docker_image.id,
          step_id: step.id,
          name: spec[:method_name]
        )
        unless std_method
          summary[:missing] << "std_method:#{spec[:method_name]}"
          next
        end

        obj_attrs = Basic.safe_parse_json(std_method.obj_attrs_json, {})
        if Basic.json_flag_true?(obj_attrs[Basic::LARGE_DATASET_OK_ATTR])
          summary[:unchanged] << "std_method:#{spec[:method_name]}##{std_method.id}"
          next
        end

        obj_attrs = obj_attrs.merge(Basic::LARGE_DATASET_OK_ATTR => true)
        std_method.update!(obj_attrs_json: JSON.pretty_generate(obj_attrs))
        summary[:updated] << "std_method:#{spec[:method_name]}##{std_method.id}"
      end

      summary
    end

    private

    def resolve_docker_image!(version_id, docker_image_id)
      return DockerImage.find(docker_image_id) if docker_image_id.present?

      version = Version.find_by(id: version_id)
      raise "Version #{version_id} not found" unless version

      docker_image = Basic.get_asap_docker(version)
      raise "No ASAP docker image for version #{version_id}" unless docker_image

      docker_image
    end
  end
end
