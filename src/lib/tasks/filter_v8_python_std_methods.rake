# frozen_string_literal: true

require_relative "../filter_v8_python_std_methods"

namespace :reference_data do
  desc "Switch v8 cell/gene filtering commands from java -jar ASAP.jar -T FilterCols/FilterRows to " \
       "python3 /srv/filter.v8.py (needs an asap_run:v8 image that contains filter.v8.py). " \
       "DRY_RUN=1 to preview. Optional VERSION_ID=8 DOCKER_IMAGE_ID=<id>"
  task filter_v8_python_std_methods: :environment do
    version_id = ENV.fetch("VERSION_ID", FilterV8PythonStdMethods::VERSION_ID).to_i
    docker_image_id = ENV["DOCKER_IMAGE_ID"].presence&.to_i
    dry_run = %w[1 true yes].include?(ENV["DRY_RUN"].to_s.strip.downcase)

    summary = FilterV8PythonStdMethods.apply!(
      version_id: version_id,
      docker_image_id: docker_image_id,
      dry_run: dry_run
    )

    puts "#{dry_run ? '[DRY RUN] ' : ''}v#{version_id} filtering commands switched to #{FilterV8PythonStdMethods::PYTHON_PROGRAM}:"
    if summary[:changes].empty?
      puts "  (none: no Step/StdMethod command runs java -jar ASAP.jar -T FilterCols/FilterRows)"
    else
      summary[:changes].each do |c|
        puts "  #{c[:model]} ##{c[:id]} #{c[:name]} [#{c[:mode]}]: #{c[:from].inspect} -> #{c[:to].inspect}"
      end
    end
    puts "  other std_methods left unchanged: #{summary[:unchanged]}"
  end
end
