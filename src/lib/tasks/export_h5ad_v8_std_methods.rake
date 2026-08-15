# frozen_string_literal: true

require_relative '../export_h5ad_v8_std_methods'

namespace :reference_data do
  desc 'Upsert the v8 export_h5ad step and loom_to_h5ad StdMethod. Optional VERSION_ID=8 DOCKER_IMAGE_ID='
  task export_h5ad_v8_std_methods: :environment do
    version_id = ENV.fetch('VERSION_ID', ExportH5adV8StdMethods::VERSION_ID).to_i
    docker_image_id = ENV['DOCKER_IMAGE_ID'].presence&.to_i

    summary = ExportH5adV8StdMethods.upsert!(
      version_id: version_id,
      docker_image_id: docker_image_id
    )

    puts "Export H5AD v#{version_id} std_methods:"
    puts "  step_id:   #{summary[:step_id]}"
    puts "  created:   #{summary[:created].join(', ').presence || '(none)'}"
    puts "  updated:   #{summary[:updated].join(', ').presence || '(none)'}"
    puts "  unchanged: #{summary[:unchanged].join(', ').presence || '(none)'}"
  end
end
