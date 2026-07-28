# frozen_string_literal: true

namespace :asap_data do
  desc "Populate assemblies from Ensembl meta.txt under ENSEMBL_DATA_DIR (default: largest local ensembl tree). ENV: ASAP2_REMOTE_DB, ENSEMBL_DATA_DIR, ENSEMBL_DB_TYPES, ENSEMBL_RELEASE_FROM (default: 54 vertebrates, 1 ensembl genomes), ENSEMBL_RELEASE_TO (default: organism/subdomain latest or 116), DOWNLOAD_MISSING_META, TRUNCATE_ASSEMBLIES"
  task populate_assemblies: :environment do
    dev_null = Logger.new("/dev/null")
    Rails.logger = dev_null
    ActiveRecord::Base.logger = dev_null

    start = Time.now
    base_dirs = AsapData::EnsemblAssembliesLoader.all_ensembl_base_dirs
    remote_db = ENV["ASAP2_REMOTE_DB"].presence || "asap_data_v8"
    download_missing_meta = AsapData::EnsemblAssembliesLoader.default_download_missing_meta?

    puts "Populate assemblies"
    puts "  ensembl data dirs: #{base_dirs.map(&:to_s).join(', ')}"
    puts "  remote db: #{remote_db}"
    truncate_assemblies = ENV.fetch("TRUNCATE_ASSEMBLIES", "false").to_s.strip.downcase == "true"
    puts "  truncate assemblies: #{truncate_assemblies}"
    puts "  download missing meta: #{download_missing_meta}"
    puts

    if truncate_assemblies
      AsapData::EnsemblAssembliesLoader.truncate_assemblies!(remote_db: remote_db)
      puts "Truncated assemblies (RESTART IDENTITY)"
      puts
    end

    stats = AsapData::EnsemblAssembliesLoader.populate!(
      remote_db: remote_db,
      download_missing_meta: download_missing_meta
    )

    elapsed = Time.now - start
    puts
    puts "Done in #{elapsed.round(1)}s"
    puts "  organisms total: #{stats[:organisms_total]}"
    puts "  organisms with assembly: #{stats[:organisms_with_assembly]}"
    puts "  organisms without assembly: #{stats[:organisms_without_assembly]}"
    puts "  assembly names found: #{stats[:assembly_names_found]}"
    puts "  meta downloads: #{stats[:meta_downloads]}"
    puts "  assemblies created: #{stats[:assemblies_created]}"
    puts "  assemblies updated: #{stats[:assemblies_updated]}"
    puts "  skipped (no meta): #{stats[:skipped_no_meta]}"
    puts "  skipped (unknown subdomain): #{stats[:skipped_unknown_subdomain]}"

    RemoteAssembly.with_remote(remote_db) do
      puts "  total assemblies in db: #{RemoteAssembly.count}"
    end
  end
end
