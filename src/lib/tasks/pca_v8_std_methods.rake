# frozen_string_literal: true

require_relative "../pca_v8_std_methods"

namespace :reference_data do
  desc "Upsert v8 Scanpy PCA StdMethod (pca). Optional VERSION_ID=8 DOCKER_IMAGE_ID="
  task pca_v8_std_methods: :environment do
    version_id = ENV.fetch("VERSION_ID", PcaV8StdMethods::VERSION_ID).to_i
    docker_image_id = ENV["DOCKER_IMAGE_ID"].presence&.to_i

    summary = PcaV8StdMethods.upsert!(
      version_id: version_id,
      docker_image_id: docker_image_id
    )

    puts "PCA v#{version_id} std_methods:"
    puts "  created:   #{summary[:created].join(', ').presence || '(none)'}"
    puts "  updated:   #{summary[:updated].join(', ').presence || '(none)'}"
    puts "  unchanged: #{summary[:unchanged].join(', ').presence || '(none)'}"
  end
end
