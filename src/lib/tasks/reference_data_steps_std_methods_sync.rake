# frozen_string_literal: true

require "tempfile"
require "json"
require_relative "../reference_data_steps_std_methods_sync"

namespace :reference_data do
  namespace :steps_std_methods do
    class SourceReferenceBase < ActiveRecord::Base
      self.abstract_class = true
    end

    class SourceStep < SourceReferenceBase
      self.table_name = "steps"
    end

    class SourceStdMethod < SourceReferenceBase
      self.table_name = "std_methods"
    end

    class SourceDockerImage < SourceReferenceBase
      self.table_name = "docker_images"
    end

    class SourceVersion < SourceReferenceBase
      self.table_name = "versions"
    end

    class SourceSpeed < SourceReferenceBase
      self.table_name = "speeds"
    end

    def source_db_config_for_reference_sync
      database_url = ENV["SOURCE_DATABASE_URL"].to_s.strip
      return { url: database_url } if database_url.present?

      dev_postgres_db = ENV["DEV_POSTGRES_DB"].to_s.strip
      return nil if dev_postgres_db.empty?

      {
        adapter: "postgresql",
        host: ENV.fetch("DEV_DB_HOST", ENV.fetch("SOURCE_DB_HOST", "postgres")),
        port: ENV.fetch("DEV_DB_PORT", ENV.fetch("SOURCE_DB_PORT", ENV.fetch("POSTGRES_PORT", "5434"))).to_i,
        database: dev_postgres_db,
        username: ENV.fetch("POSTGRES_USER"),
        password: ENV.fetch("POSTGRES_PASSWORD"),
        encoding: "unicode"
      }
    end

    def source_records_for_reference_sync(source_model)
      source_model.order(:id).map(&:attributes)
    end

    def build_temp_snapshot_from_source_db_for_reference_sync!
      source_cfg = source_db_config_for_reference_sync
      return nil if source_cfg.nil?

      SourceReferenceBase.establish_connection(source_cfg)
      payload = {
        "label" => "source_db",
        "records" => {
          "Step" => source_records_for_reference_sync(SourceStep),
          "StdMethod" => source_records_for_reference_sync(SourceStdMethod),
          "DockerImage" => source_records_for_reference_sync(SourceDockerImage),
          "Version" => source_records_for_reference_sync(SourceVersion),
          "Speed" => source_records_for_reference_sync(SourceSpeed)
        }
      }

      tmp = Tempfile.new(["reference_data_steps_std_methods", ".json"])
      tmp.write(JSON.pretty_generate(payload))
      tmp.flush
      tmp
    ensure
      SourceReferenceBase.remove_connection
    end

    desc "Sync Step and StdMethod from SNAPSHOT=export.json (DRY_RUN=1, VERBOSE=1). Export with MODELS=Step,StdMethod,DockerImage,Version,Speed as needed."
    task sync: :environment do
      path = ENV["SNAPSHOT"].to_s.strip
      generated_snapshot = nil
      if path.empty?
        generated_snapshot = build_temp_snapshot_from_source_db_for_reference_sync!
        path = generated_snapshot&.path.to_s
      end

      if path.empty?
        puts "Usage:"
        puts "  RAILS_ENV=production bin/rake reference_data:steps_std_methods:sync SNAPSHOT=/path/to/snapshot.json"
        puts "  or set DEV_POSTGRES_DB=... (and optional DEV_DB_HOST/DEV_DB_PORT) to auto-build snapshot from source DB."
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
    ensure
      generated_snapshot&.close!
    end
  end
end
