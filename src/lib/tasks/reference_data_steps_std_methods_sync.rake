# frozen_string_literal: true

require "tempfile"
require "json"
require_relative "../reference_data_steps_std_methods_sync"
require_relative "../reference_data_steps_std_methods_compare"

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

    def dev_db_config_for_reference_sync
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

    def production_db_config_for_reference_sync
      database_url = ENV["SOURCE_DATABASE_URL"].to_s.strip
      return { url: database_url } if database_url.present?

      prod_postgres_db = ENV["PROD_POSTGRES_DB"].to_s.strip
      return nil if prod_postgres_db.empty?

      {
        adapter: "postgresql",
        host: ENV.fetch("PROD_DB_HOST", ENV.fetch("SOURCE_DB_HOST", "host.docker.internal")),
        port: ENV.fetch("PROD_DB_PORT", ENV.fetch("SOURCE_DB_PORT", "5433")).to_i,
        database: prod_postgres_db,
        username: ENV.fetch("POSTGRES_USER"),
        password: ENV.fetch("POSTGRES_PASSWORD"),
        encoding: "unicode"
      }
    end

    def source_db_config_for_reference_sync
      dev_db_config_for_reference_sync
    end

    def source_records_for_reference_sync(source_model)
      source_model.order(:id).map(&:attributes)
    end

    def legacy_version_scope(max_version_id)
      ["version_id IS NOT NULL AND version_id < ?", max_version_id]
    end

    def load_reference_rows_from_db!(db_config, max_version_id: nil, exclude_deprecated: false)
      SourceReferenceBase.establish_connection(db_config)
      step_scope = max_version_id ? legacy_version_scope(max_version_id) : nil
      std_method_scope = step_scope
      steps = if step_scope
        relation = SourceStep.where(step_scope)
        exclude_deprecated ? relation.where(hidden: [false, nil]) : relation
      else
        exclude_deprecated ? SourceStep.where(hidden: [false, nil]) : SourceStep.all
      end
      std_methods = if std_method_scope
        relation = SourceStdMethod.where(std_method_scope)
        exclude_deprecated ? relation.where(obsolete: [false, nil]) : relation
      else
        exclude_deprecated ? SourceStdMethod.where(obsolete: [false, nil]) : SourceStdMethod.all
      end
      step_rows = steps.order(:id).map(&:attributes)
      step_ids = step_rows.map { |row| row["id"] }
      std_method_rows =
        if step_ids.empty?
          []
        else
          std_methods.where(step_id: step_ids).order(:id).map(&:attributes)
        end
      {
        steps: step_rows,
        std_methods: std_method_rows,
        docker_images: SourceDockerImage.order(:id).map(&:attributes),
        versions: SourceVersion.order(:id).map(&:attributes),
        speeds: SourceSpeed.order(:id).map(&:attributes)
      }
    ensure
      SourceReferenceBase.remove_connection
    end

    def build_temp_snapshot_from_rows!(rows, label:)
      payload = {
        "label" => label,
        "records" => {
          "Step" => rows[:steps],
          "StdMethod" => rows[:std_methods],
          "DockerImage" => rows[:docker_images],
          "Version" => rows[:versions],
          "Speed" => rows[:speeds]
        }
      }

      tmp = Tempfile.new(["reference_data_steps_std_methods", ".json"])
      tmp.write(JSON.pretty_generate(payload))
      tmp.flush
      tmp
    end

    def load_source_reference_rows_for_compare!(max_version_id)
      source_cfg = source_db_config_for_reference_sync
      return nil if source_cfg.nil?

      load_reference_rows_from_db!(
        source_cfg,
        max_version_id: max_version_id,
        exclude_deprecated: true
      )
    end

    def build_temp_snapshot_from_source_db_for_reference_sync!
      source_cfg = source_db_config_for_reference_sync
      return nil if source_cfg.nil?

      rows = load_reference_rows_from_db!(source_cfg)
      build_temp_snapshot_from_rows!(rows, label: "source_db")
    end

    def build_temp_snapshot_from_production_db_for_legacy_sync!(max_version_id)
      source_cfg = production_db_config_for_reference_sync
      return nil if source_cfg.nil?

      rows = load_reference_rows_from_db!(
        source_cfg,
        max_version_id: max_version_id,
        exclude_deprecated: true
      )
      build_temp_snapshot_from_rows!(rows, label: "production_legacy")
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

    desc "Compare Step and StdMethod with version_id < MAX_VERSION_ID (default 8) between source DB (dev) and current DB. " \
         "Obsolete std_methods and hidden steps are excluded. Set SOURCE_DATABASE_URL or DEV_POSTGRES_DB. VERBOSE=1, OUT=report.json"
    task compare_legacy_versions: :environment do
      max_version_id = ENV.fetch("MAX_VERSION_ID", "8").to_i
      verbose = ENV["VERBOSE"].to_s.strip == "1"
      out_path = ENV["OUT"].to_s.strip

      source_rows = load_source_reference_rows_for_compare!(max_version_id)
      if source_rows.nil?
        puts "Usage:"
        puts "  RAILS_ENV=production bin/rake reference_data:steps_std_methods:compare_legacy_versions"
        puts "  Set SOURCE_DATABASE_URL=... or DEV_POSTGRES_DB=... (and optional DEV_DB_HOST/DEV_DB_PORT)."
        puts "Optional:"
        puts "  MAX_VERSION_ID=8   (compare rows where version_id < this value, default 8)"
        puts "  VERBOSE=1          (no truncation in field diffs)"
        puts "  OUT=/path/to/report.json"
        exit 1
      end

      report = ReferenceDataStepsStdMethodsCompare.new(
        source_steps: source_rows[:steps],
        source_std_methods: source_rows[:std_methods],
        source_docker_images: source_rows[:docker_images],
        source_versions: source_rows[:versions],
        source_speeds: source_rows[:speeds],
        max_version_id: max_version_id,
        verbose: verbose
      ).run

      if out_path.present?
        File.write(out_path, JSON.pretty_generate(serialize_compare_report(report)))
        puts "JSON report written to #{out_path}"
      end

      exit 1 if report[:has_differences]
    end

    desc "Apply Step and StdMethod with version_id < MAX_VERSION_ID from production to the current DB (development). " \
         "Set PROD_POSTGRES_DB or SOURCE_DATABASE_URL (+ optional PROD_DB_HOST/PROD_DB_PORT). DRY_RUN=1, VERBOSE=1"
    task sync_legacy_versions_to_dev: :environment do
      if Rails.env.production?
        puts "This task writes to the current database. Run with RAILS_ENV=development so the target is development."
        exit 1
      end

      max_version_id = ENV.fetch("MAX_VERSION_ID", "8").to_i
      dry = ENV["DRY_RUN"].to_s.strip == "1"
      verbose = ENV["VERBOSE"].to_s.strip == "1"
      generated_snapshot = build_temp_snapshot_from_production_db_for_legacy_sync!(max_version_id)

      if generated_snapshot.nil?
        puts "Usage:"
        puts "  RAILS_ENV=development bin/rake reference_data:steps_std_methods:sync_legacy_versions_to_dev"
        puts "  Set PROD_POSTGRES_DB=... or SOURCE_DATABASE_URL=... (and optional PROD_DB_HOST/PROD_DB_PORT)."
        puts "Optional:"
        puts "  MAX_VERSION_ID=8   (apply rows where version_id < this value, default 8)"
        puts "  DRY_RUN=1        (preview changes, transaction rolled back)"
        puts "  VERBOSE=1        (print per-column diffs for updates)"
        exit 1
      end

      puts "Applying production Step/StdMethod (version_id < #{max_version_id}) to #{Rails.env} database"
      ReferenceDataStepsStdMethodsSync.new(
        snapshot_path: generated_snapshot.path,
        dry_run: dry,
        verbose: verbose,
        max_version_id: max_version_id
      ).run
    ensure
      generated_snapshot&.close!
    end

    def serialize_compare_report(report)
      {
        "max_version_id" => report[:max_version_id],
        "version_filter" => report[:version_filter],
        "compared_at" => Time.now.utc.iso8601,
        "target_env" => Rails.env,
        "has_differences" => report[:has_differences],
        "steps" => serialize_step_compare_report(report[:steps]),
        "std_methods" => serialize_std_method_compare_report(report[:std_methods])
      }
    end

    def serialize_step_compare_report(payload)
      {
        "source_count" => payload[:source_count],
        "target_count" => payload[:target_count],
        "only_in_source" => payload[:only_in_source],
        "only_in_target" => payload[:only_in_target],
        "changed_count" => payload[:changed_count],
        "changed" => payload[:changed].transform_keys(&:to_s)
      }
    end

    def serialize_std_method_compare_report(payload)
      {
        "source_count" => payload[:source_count],
        "target_count" => payload[:target_count],
        "only_in_source" => payload[:only_in_source],
        "only_in_target" => payload[:only_in_target],
        "changed_count" => payload[:changed_count],
        "changed" => payload[:changed].transform_keys(&:to_s)
      }
    end
  end
end
