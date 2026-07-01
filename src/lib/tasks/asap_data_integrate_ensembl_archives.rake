# frozen_string_literal: true

namespace :asap_data do
  desc "Merge loose organism files into .tgz archives and remove organism directories. ENV: ENSEMBL_DATA_DIR, ENSEMBL_DB_TYPES, ENSEMBL_RELEASE_FROM, ENSEMBL_RELEASE_TO, ORGANISM_ID, ENSEMBL_DB_NAME, DRY_RUN, CREATE_MISSING_ARCHIVES"
  task integrate_ensembl_archives: :environment do
    dev_null = Logger.new("/dev/null")
    Rails.logger = dev_null
    ActiveRecord::Base.logger = dev_null

    start = Time.now
    base_dirs = AsapData::EnsemblAssembliesLoader.all_ensembl_base_dirs
    dry_run = AsapData::EnsemblArchiveIntegrator.default_dry_run?
    create_missing = AsapData::EnsemblArchiveIntegrator.default_create_missing_archives?

    puts "Integrate loose Ensembl files into .tgz archives"
    puts "  ensembl data dirs: #{base_dirs.map(&:to_s).join(', ')}"
    puts "  dry run: #{dry_run}"
    puts "  create missing archives: #{create_missing}"
    puts

    stats = AsapData::EnsemblArchiveIntegrator.integrate!(
      dry_run: dry_run,
      create_missing_archives: create_missing
    )

    elapsed = Time.now - start
    puts
    puts "Done in #{elapsed.round(1)}s"
    puts "  organisms checked: #{stats[:organisms_checked]}"
    puts "  archives updated: #{stats[:archives_updated]}"
    puts "  archives created: #{stats[:archives_created]}"
    puts "  organism dirs removed: #{stats[:dirs_removed]}"
    puts "  skipped (no dir): #{stats[:skipped_no_dir]}"
    puts "  skipped (no files): #{stats[:skipped_no_files]}"
    puts "  skipped (no archive): #{stats[:skipped_no_archive]}"
    puts "  failed: #{stats[:failed]}"
  end
end
