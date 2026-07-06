# frozen_string_literal: true

require_relative "../heatmap_v8_std_methods"

namespace :reference_data do
  desc "Upsert the v8 Heatmap step and StdMethod. Optional VERSION_ID=8 DOCKER_IMAGE_ID="
  task heatmap_v8_std_methods: :environment do
    version_id = ENV.fetch("VERSION_ID", HeatmapV8StdMethods::VERSION_ID).to_i
    docker_image_id = ENV["DOCKER_IMAGE_ID"].presence&.to_i

    summary = HeatmapV8StdMethods.upsert!(
      version_id: version_id,
      docker_image_id: docker_image_id
    )

    puts "Heatmap v#{version_id} std_methods:"
    puts "  created:   #{summary[:created].join(', ').presence || '(none)'}"
    puts "  updated:   #{summary[:updated].join(', ').presence || '(none)'}"
    puts "  unchanged: #{summary[:unchanged].join(', ').presence || '(none)'}"
  end
end
