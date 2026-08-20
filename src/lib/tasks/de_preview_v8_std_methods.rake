# frozen_string_literal: true

require_relative '../de_preview_v8_std_methods'

namespace :reference_data do
  desc 'Upsert preview_cell_fraction predict_params/attrs/opts on v8 DE StdMethods using de.v8.py or de_approx.v8.py'
  task de_preview_v8_std_methods: :environment do
    version_id = ENV.fetch('VERSION_ID', DePreviewV8StdMethods::VERSION_ID).to_i
    docker_image_id = ENV['DOCKER_IMAGE_ID']
    summary = DePreviewV8StdMethods.upsert!(
      version_id: version_id,
      docker_image_id: docker_image_id.presence
    )
    puts summary.inspect
  end
end
