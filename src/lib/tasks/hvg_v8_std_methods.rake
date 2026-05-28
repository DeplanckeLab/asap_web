# frozen_string_literal: true

require_relative "../hvg_v8_std_methods"

namespace :reference_data do
  desc "Upsert v8 HVG StdMethods (update R-based vst/dispersion, create Python seurat/seurat_v3/cell_ranger). Optional VERSION_ID=8 DOCKER_IMAGE_ID=5"
  task hvg_v8_std_methods: :environment do
    version_id = ENV.fetch("VERSION_ID", HvgV8StdMethods::VERSION_ID).to_i
    docker_image_id = ENV["DOCKER_IMAGE_ID"].presence&.to_i

    summary = HvgV8StdMethods.upsert!(
      version_id: version_id,
      docker_image_id: docker_image_id
    )

    puts "HVG v#{version_id} std_methods:"
    puts "  created:   #{summary[:created].join(', ').presence || '(none)'}"
    puts "  updated:   #{summary[:updated].join(', ').presence || '(none)'}"
    puts "  unchanged: #{summary[:unchanged].join(', ').presence || '(none)'}"
  end
end
