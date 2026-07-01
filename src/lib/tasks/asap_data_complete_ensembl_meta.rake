# frozen_string_literal: true

namespace :asap_data do
  desc "Download missing meta.txt and coord_system.txt for local Ensembl organism archives. ENV: ENSEMBL_DATA_DIR, ENSEMBL_DB_TYPES, ENSEMBL_RELEASE_FROM, ENSEMBL_RELEASE_TO, ORGANISM_ID, ENSEMBL_DB_NAME"
  task complete_ensembl_meta_files: :environment do
    dev_null = Logger.new("/dev/null")
    Rails.logger = dev_null
    ActiveRecord::Base.logger = dev_null

    start = Time.now
    base_dirs = AsapData::EnsemblAssembliesLoader.all_ensembl_base_dirs

    puts "Complete local Ensembl meta.txt and coord_system.txt"
    puts "  ensembl data dirs: #{base_dirs.map(&:to_s).join(', ')}"
    puts

    stats = AsapData::EnsemblAssembliesLoader.complete_local_meta_files!

    elapsed = Time.now - start
    puts
    puts "Done in #{elapsed.round(1)}s"
    puts "  filesystem scan: #{stats[:scan_elapsed].round(1)}s"
    puts "  organisms checked: #{stats[:organisms_checked]}"
    puts "  already complete: #{stats[:already_complete]}"
    puts "  missing entries: #{stats[:missing_entries]}"
    puts "  meta.txt downloaded: #{stats[:meta_downloaded]}"
    puts "  coord_system.txt downloaded: #{stats[:coord_system_downloaded]}"
    puts "  meta.txt failed: #{stats[:meta_failed]}"
    puts "  coord_system.txt failed: #{stats[:coord_system_failed]}"
    puts "  skipped (no core folder on FTP): #{stats[:skipped_no_core]}"
  end
end
