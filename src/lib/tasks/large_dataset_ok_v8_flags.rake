# frozen_string_literal: true

require_relative '../large_dataset_ok_v8_flags'

namespace :asap do
  desc 'Set large_dataset_ok on v8 cell_filtering / import_metadata steps and t_test_approx'
  task large_dataset_ok_v8_flags: :environment do
    version_id = ENV.fetch('VERSION_ID', LargeDatasetOkV8Flags::VERSION_ID).to_i
    docker_image_id = ENV['DOCKER_IMAGE_ID'].presence
    summary = LargeDatasetOkV8Flags.upsert!(
      version_id: version_id,
      docker_image_id: docker_image_id
    )
    puts "updated: #{summary[:updated].join(', ')}" if summary[:updated].any?
    puts "unchanged: #{summary[:unchanged].join(', ')}" if summary[:unchanged].any?
    puts "missing: #{summary[:missing].join(', ')}" if summary[:missing].any?
  end
end
