# frozen_string_literal: true

namespace :asap_data do
  desc "Backfill assemblies.insdc_accession from Ensembl meta.txt (assembly.accession). ENV: ASAP2_REMOTE_DB, ENSEMBL_DATA_DIR, DOWNLOAD_MISSING_META"
  task backfill_assembly_insdc_accessions: :environment do
    dev_null = Logger.new("/dev/null")
    Rails.logger = dev_null
    ActiveRecord::Base.logger = dev_null

    start = Time.now
    base_dirs = AsapData::EnsemblAssembliesLoader.all_ensembl_base_dirs
    remote_db = ENV["ASAP2_REMOTE_DB"].presence || "asap_data_v8"
    download_missing_meta = AsapData::EnsemblAssembliesLoader.default_download_missing_meta?

    puts "Backfill assembly INSDC accessions"
    puts "  ensembl data dirs: #{base_dirs.map(&:to_s).join(', ')}"
    puts "  remote db: #{remote_db}"
    puts "  download missing meta: #{download_missing_meta}"
    puts

    stats = AsapData::EnsemblAssembliesLoader.backfill_insdc_accessions!(
      remote_db: remote_db,
      download_missing_meta: download_missing_meta
    )

    elapsed = Time.now - start
    puts
    puts "Done in #{elapsed.round(1)}s"
    puts "  organisms total: #{stats[:organisms_total]}"
    puts "  accessions updated: #{stats[:accessions_updated]}"
    puts "  accessions already set: #{stats[:accessions_already_set]}"
    puts "  accessions missing (no meta): #{stats[:accessions_missing]}"
    puts "  meta downloads: #{stats[:meta_downloads]}"
    puts "  skipped (no meta): #{stats[:skipped_no_meta]}"
  end
end
