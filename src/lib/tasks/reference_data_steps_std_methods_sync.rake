# frozen_string_literal: true

require_relative "../reference_data_steps_std_methods_sync"

namespace :reference_data do
  namespace :steps_std_methods do
    desc "Sync Step and StdMethod from SNAPSHOT=export.json (DRY_RUN=1, VERBOSE=1). Export with MODELS=Step,StdMethod,DockerImage,Version,Speed as needed."
    task sync: :environment do
      path = ENV["SNAPSHOT"].to_s.strip
      if path.empty?
        puts "Usage:"
        puts "  RAILS_ENV=production bin/rake reference_data:steps_std_methods:sync SNAPSHOT=/path/to/snapshot.json"
        puts "  Add DRY_RUN=1 to preview changes (transaction rolled back)."
        puts ""
        puts "Generate the snapshot from a reference environment, for example:"
        puts "  bin/rake reference_data:export LABEL=dev OUT=/tmp/ref.json \\"
        puts "    MODELS=Step,StdMethod,DockerImage,Version,Speed"
        exit 1
      end

      dry = ENV["DRY_RUN"].to_s.strip == "1"
      verbose = ENV["VERBOSE"].to_s.strip == "1"

      ReferenceDataStepsStdMethodsSync.new(
        snapshot_path: path,
        dry_run: dry,
        verbose: verbose
      ).run
    end
  end
end
