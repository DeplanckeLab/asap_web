# frozen_string_literal: true

require "tempfile"
require "json"
require "open3"
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

    class SourceDockerBuild < SourceReferenceBase
      self.table_name = "docker_builds"
    end

    class SourceVersion < SourceReferenceBase
      self.table_name = "versions"
    end

    class SourceSpeed < SourceReferenceBase
      self.table_name = "speeds"
    end

    class SourceNewsItem < SourceReferenceBase
      self.table_name = "news_items"
    end

    class SourceCellOntology < SourceReferenceBase
      self.table_name = "cell_ontologies"
    end

    class SourceOntologyTermType < SourceReferenceBase
      self.table_name = "ontology_term_types"
    end

    class SourceUploadType < SourceReferenceBase
      self.table_name = "upload_types"
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

    def load_reference_rows_from_db!(db_config, max_version_id: nil, exclude_hidden: false, exclude_obsolete: false)
      SourceReferenceBase.establish_connection(db_config)
      step_scope = max_version_id ? legacy_version_scope(max_version_id) : nil
      std_method_scope = step_scope
      steps = if step_scope
        relation = SourceStep.where(step_scope)
        exclude_hidden ? relation.where(hidden: [false, nil]) : relation
      else
        exclude_hidden ? SourceStep.where(hidden: [false, nil]) : SourceStep.all
      end
      std_methods = if std_method_scope
        relation = SourceStdMethod.where(std_method_scope)
        exclude_obsolete ? relation.where(obsolete: [false, nil]) : relation
      else
        exclude_obsolete ? SourceStdMethod.where(obsolete: [false, nil]) : SourceStdMethod.all
      end
      step_rows = steps.order(:id).map(&:attributes)
      step_ids = step_rows.map { |row| row["id"] }
      std_method_rows =
        if step_ids.empty?
          []
        else
          std_methods.where(step_id: step_ids).order(:id).map(&:attributes)
        end
      news_items =
        if SourceReferenceBase.connection.table_exists?(:news_items)
          SourceNewsItem.order(:id).map(&:attributes)
        end
      cell_ontologies =
        if SourceReferenceBase.connection.table_exists?(:cell_ontologies)
          SourceCellOntology.order(:id).map(&:attributes)
        end
      ontology_term_types =
        if SourceReferenceBase.connection.table_exists?(:ontology_term_types)
          SourceOntologyTermType.order(:id).map(&:attributes)
        end
      upload_types =
        if SourceReferenceBase.connection.table_exists?(:upload_types)
          SourceUploadType.order(:id).map(&:attributes)
        end
      payload_rows = {
        steps: step_rows,
        std_methods: std_method_rows,
        docker_images: SourceDockerImage.order(:id).map(&:attributes),
        docker_builds: SourceDockerBuild.order(:id).map(&:attributes),
        versions: SourceVersion.order(:id).map(&:attributes),
        speeds: SourceSpeed.order(:id).map(&:attributes)
      }
      payload_rows[:news_items] = news_items unless news_items.nil?
      payload_rows[:cell_ontologies] = cell_ontologies unless cell_ontologies.nil?
      payload_rows[:ontology_term_types] = ontology_term_types unless ontology_term_types.nil?
      payload_rows[:upload_types] = upload_types unless upload_types.nil?
      payload_rows
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
          "DockerBuild" => rows[:docker_builds],
          "Version" => rows[:versions],
          "Speed" => rows[:speeds]
        }
      }
      payload["records"]["NewsItem"] = rows[:news_items] if rows.key?(:news_items)
      payload["records"]["CellOntology"] = rows[:cell_ontologies] if rows.key?(:cell_ontologies)
      payload["records"]["OntologyTermType"] = rows[:ontology_term_types] if rows.key?(:ontology_term_types)
      payload["records"]["UploadType"] = rows[:upload_types] if rows.key?(:upload_types)

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
        exclude_hidden: false,
        exclude_obsolete: true
      )
    end

    def build_temp_snapshot_from_source_db_for_reference_sync!(max_version_id: nil, exclude_hidden: false, exclude_obsolete: false)
      source_cfg = source_db_config_for_reference_sync
      return nil if source_cfg.nil?

      rows = load_reference_rows_from_db!(
        source_cfg,
        max_version_id: max_version_id,
        exclude_hidden: exclude_hidden,
        exclude_obsolete: exclude_obsolete
      )
      build_temp_snapshot_from_rows!(rows, label: "source_db")
    end

    def build_temp_snapshot_from_production_db_for_legacy_sync!(max_version_id)
      source_cfg = production_db_config_for_reference_sync
      return nil if source_cfg.nil?

      rows = load_reference_rows_from_db!(
        source_cfg,
        max_version_id: max_version_id,
        exclude_hidden: false,
        exclude_obsolete: true
      )
      build_temp_snapshot_from_rows!(rows, label: "production_legacy")
    end

    def highest_docker_build_tag(tags)
      tags
        .map(&:to_s)
        .select { |tag| tag.match?(/\Av\d+(\.\d+)?\z/) }
        .max_by { |tag| Gem::Version.new(tag.delete_prefix("v")) }
    end

    def docker_inspect_format!(container, format)
      stdout, stderr, status = Open3.capture3(
        "docker", "inspect", "-f", format, container
      )
      unless status.success?
        raise "docker inspect failed for #{container}: #{stderr.strip}"
      end

      stdout.strip
    end

    def run_host_cmd!(*args)
      puts "+ #{args.join(' ')}"
      stdout, stderr, status = Open3.capture3(*args)
      $stdout.print(stdout) unless stdout.empty?
      $stderr.print(stderr) unless stderr.empty?
      raise "Command failed (#{status.exitstatus}): #{args.join(' ')}" unless status.success?

      stdout
    end

    # website has docker.sock but not the compose plugin or the compose project tree.
    # Run host docker-compose via a one-off alpine container with host paths bind-mounted.
    def run_compose_on_host!(working_dir:, compose_file:, project:, compose_args:)
      compose_bin = ENV.fetch("DOCKER_COMPOSE_BIN", "/usr/local/bin/docker-compose")
      asap_run_dir = ENV.fetch("ASAP_RUN_DIR", "/srv/asap_run_new")
      cmd = [
        "docker", "run", "--rm",
        "-v", "/var/run/docker.sock:/var/run/docker.sock",
        "-v", "#{compose_bin}:/usr/local/bin/docker-compose:ro",
        "-v", "#{working_dir}:#{working_dir}",
        "-v", "#{asap_run_dir}:#{asap_run_dir}",
        "-w", working_dir,
        "--entrypoint", "/usr/local/bin/docker-compose",
        ENV.fetch("COMPOSE_RUNNER_IMAGE", "alpine:latest"),
        "-p", project,
        "-f", File.basename(compose_file),
        *compose_args
      ]
      run_host_cmd!(*cmd)
    end

    # When sync_from_dev creates DockerBuild rows, rebuild the long-running compose asap_run
    # service with the highest newly created tag that has a Dockerfile on disk.
    # Set SKIP_COMPOSE=1 to skip (e.g. bulk historical DockerBuild import).
    def maybe_rebuild_compose_asap_run_after_docker_build_sync!(summary, dry_run:)
      created_tags = Array(summary[:docker_builds_created_tags]).map(&:to_s).reject(&:empty?)
      return if created_tags.empty?

      if ENV["SKIP_COMPOSE"].to_s.strip == "1"
        puts "SKIP_COMPOSE=1: not rebuilding compose asap_run " \
             "(created DockerBuild tags: #{created_tags.join(', ')})"
        return
      end

      asap_run_dir = ENV.fetch("ASAP_RUN_DIR", "/srv/asap_run_new")
      tag = highest_docker_build_tag(created_tags)
      if tag.nil?
        puts "New DockerBuild tags are not version-shaped; not rebuilding compose asap_run: " \
             "#{created_tags.join(', ')}"
        return
      end

      dockerfile_name = "Dockerfile.#{tag}"
      dockerfile_path = File.join(asap_run_dir, dockerfile_name)
      unless File.file?(dockerfile_path)
        puts "Dockerfile missing for created DockerBuild tag #{tag}: #{dockerfile_path}"
        puts "Add it under #{asap_run_dir}, then rebuild compose asap_run manually."
        return
      end

      if dry_run
        puts "[dry-run] would rebuild compose asap_run with #{dockerfile_name} " \
             "(created tags: #{created_tags.join(', ')})"
        return
      end

      container = ENV.fetch("ASAP_RUN_CONTAINER")
      image = docker_inspect_format!(container, "{{.Config.Image}}")
      working_dir = docker_inspect_format!(
        container, "{{index .Config.Labels \"com.docker.compose.project.working_dir\"}}"
      )
      config_files = docker_inspect_format!(
        container, "{{index .Config.Labels \"com.docker.compose.project.config_files\"}}"
      )
      project = docker_inspect_format!(
        container, "{{index .Config.Labels \"com.docker.compose.project\"}}"
      )
      compose_file = config_files.split(",").map(&:strip).reject(&:empty?).first

      if working_dir.empty? || compose_file.nil? || project.empty?
        raise "Compose labels missing on #{container}; cannot rebuild asap_run automatically"
      end

      puts "Rebuilding compose asap_run from new DockerBuild tag #{tag}"
      puts "  image=#{image}  dockerfile=#{dockerfile_path}"
      puts "  compose project=#{project} dir=#{working_dir} file=#{File.basename(compose_file)}"

      # Build explicitly so production's hardcoded compose dockerfile line cannot pin an older patch.
      run_host_cmd!("docker", "build", "-t", image, "-f", dockerfile_path, asap_run_dir)
      run_compose_on_host!(
        working_dir: working_dir,
        compose_file: compose_file,
        project: project,
        compose_args: ["up", "-d", "--force-recreate", "--no-build", "asap_run"]
      )
      puts "Compose asap_run recreated with #{dockerfile_name}"
    end

    # OBSOLETE: name-based snapshot sync. Prefer sync_from_dev for multi-version ASAP.
    desc "[OBSOLETE] Name-based sync from SNAPSHOT=export.json. " \
         "Cannot apply full multi-version exports (duplicate step names). " \
         "Use reference_data:steps_std_methods:sync_from_dev instead. " \
         "DRY_RUN=1, VERBOSE=1 still supported."
    task sync: :environment do
      warn "[OBSOLETE] reference_data:steps_std_methods:sync is obsolete. " \
           "Use reference_data:steps_std_methods:sync_from_dev for dev -> production."

      path = ENV["SNAPSHOT"].to_s.strip
      generated_snapshot = nil
      if path.empty?
        generated_snapshot = build_temp_snapshot_from_source_db_for_reference_sync!
        path = generated_snapshot&.path.to_s
      end

      if path.empty?
        puts "Usage (obsolete task — prefer sync_from_dev):"
        puts "  RAILS_ENV=production bin/rake reference_data:steps_std_methods:sync_from_dev DRY_RUN=1"
        puts ""
        puts "Legacy name-based sync:"
        puts "  RAILS_ENV=production bin/rake reference_data:steps_std_methods:sync SNAPSHOT=/path/to/snapshot.json"
        puts "  or set DEV_POSTGRES_DB=... (and optional DEV_DB_HOST/DEV_DB_PORT) to auto-build snapshot from source DB."
        puts "  Add DRY_RUN=1 to preview changes (transaction rolled back)."
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

    desc "Preferred: apply Step, StdMethod, Version, DockerImage, DockerBuild, NewsItem, " \
         "CellOntology, OntologyTermType, and UploadType from development to production. " \
         "Match by primary key id; version id < MAX_VERSION_ID (default 9, includes v8). " \
         "Version sync includes env_json and activated status. " \
         "NewsItem sync clears user_id and removes target-only rows. " \
         "CellOntology sync by id (create/update/delete target-only rows, including their terms). " \
         "OntologyTermType sync by id (create/update; no deletes). " \
         "UploadType sync by id (create/update; no deletes). " \
         "Also runs external_catalog:sync_from_dev unless SKIP_EXTERNAL_CATALOG=1 " \
         "(marks missing catalog entries obsolete; deletes blank-URL test entries only). " \
         "Hidden steps included; obsolete std_methods excluded. " \
         "If new DockerBuild rows are created, rebuilds compose asap_run from the highest new tag Dockerfile. " \
         "Set DEV_POSTGRES_DB (and DEV_DB_HOST/DEV_DB_PORT). DRY_RUN=1, VERBOSE=1, SKIP_COMPOSE=1, SKIP_EXTERNAL_CATALOG=1"
    task sync_from_dev: :environment do
      unless Rails.env.production?
        puts "This task writes to the current database. Run with RAILS_ENV=production so the target is production."
        exit 1
      end

      max_version_id = ENV.fetch("MAX_VERSION_ID", "9").to_i
      dry = ENV["DRY_RUN"].to_s.strip == "1"
      verbose = ENV["VERBOSE"].to_s.strip == "1"

      generated_snapshot = build_temp_snapshot_from_source_db_for_reference_sync!(
        max_version_id: max_version_id,
        exclude_hidden: false,
        exclude_obsolete: true
      )
      if generated_snapshot.nil?
        puts "Usage:"
        puts "  RAILS_ENV=production bin/rake reference_data:steps_std_methods:sync_from_dev"
        puts "  Set DEV_POSTGRES_DB=asap2_development (and DEV_DB_HOST/DEV_DB_PORT if needed)."
        puts "Optional: MAX_VERSION_ID=9  DRY_RUN=1  VERBOSE=1  SKIP_COMPOSE=1"
        exit 1
      end

      puts "Applying development Step/StdMethod/Version/DockerImage/DockerBuild/NewsItem/CellOntology/OntologyTermType/UploadType " \
           "(id < #{max_version_id}, including hidden steps) to production"
      puts "  dry_run=#{dry}  match_by=id"

      summary = ReferenceDataStepsStdMethodsSync.new(
        snapshot_path: generated_snapshot.path,
        dry_run: dry,
        verbose: verbose,
        max_version_id: max_version_id
      ).run

      maybe_rebuild_compose_asap_run_after_docker_build_sync!(summary, dry_run: dry)

      unless ENV["SKIP_EXTERNAL_CATALOG"].to_s.strip == "1"
        puts "Syncing external_catalog_candidates from development..."
        Rake::Task["external_catalog:sync_from_dev"].invoke
      end
    ensure
      generated_snapshot&.close!
    end

    desc "Compare Step and StdMethod with version_id < MAX_VERSION_ID (default 8) between source DB (dev) and current DB. " \
         "Includes hidden steps; obsolete std_methods excluded. Set SOURCE_DATABASE_URL or DEV_POSTGRES_DB. VERBOSE=1, OUT=report.json"
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
        include_hidden: true,
        verbose: verbose
      ).run

      if out_path.present?
        File.write(out_path, JSON.pretty_generate(serialize_compare_report(report)))
        puts "JSON report written to #{out_path}"
      end

      exit 1 if report[:has_differences]
    end

    desc "Apply Step and StdMethod with version_id < MAX_VERSION_ID from production to the current DB (development). " \
         "Includes hidden steps; obsolete std_methods excluded. Set PROD_POSTGRES_DB or SOURCE_DATABASE_URL. DRY_RUN=1, VERBOSE=1"
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

      puts "Applying production Step/StdMethod (version_id < #{max_version_id}, including hidden steps) to #{Rails.env} database"
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
