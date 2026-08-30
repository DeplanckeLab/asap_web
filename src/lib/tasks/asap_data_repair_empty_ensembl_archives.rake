# frozen_string_literal: true

namespace :asap_data do
  desc <<~DESC.gsub(/\s+/, " ").strip
    Find Ensembl dumps with empty required tables (gene/xref/object_xref in dirs or .tgz),
    re-download them from FTP, repack archives, then reload assemblies/genes/gene_set_items
    for affected organisms.
    ENV: ASAP2_REMOTE_DB, ENSEMBL_DATA_DIR, ENSEMBL_DB_TYPES, ENSEMBL_RELEASE_FROM,
    ENSEMBL_RELEASE_TO, ORGANISM_ID, ENSEMBL_DB_NAME, ORGANISM, DRY_RUN,
    RELOAD_DB (default true), RELOAD_GENE_SETS (default true), RESET_ITEMS (default true)
  DESC
  task repair_empty_ensembl_archives: :environment do
    dev_null = Logger.new("/dev/null")
    Rails.logger = dev_null
    ActiveRecord::Base.logger = dev_null
    $stdout.sync = true

    remote_db = AsapData::EnsemblEmptyArchiveRepairer.default_remote_db
    dry_run = AsapData::EnsemblEmptyArchiveRepairer.default_dry_run?
    reload_db = AsapData::EnsemblEmptyArchiveRepairer.default_reload_db?
    reload_gene_sets = AsapData::EnsemblEmptyArchiveRepairer.default_reload_gene_sets?
    base_dirs = AsapData::EnsemblAssembliesLoader.all_ensembl_base_dirs
    start = Time.now

    puts "Repair empty Ensembl archives"
    puts "  remote db: #{remote_db}"
    puts "  ensembl data dirs: #{base_dirs.map(&:to_s).join(', ')}"
    puts "  dry run: #{dry_run}"
    puts "  reload db: #{reload_db}"
    puts "  reload gene sets: #{reload_gene_sets}"
    puts

    stats = AsapData::EnsemblEmptyArchiveRepairer.repair!(
      remote_db: remote_db,
      dry_run: dry_run,
      reload_db: reload_db,
      reload_gene_sets: reload_gene_sets
    )

    puts
    puts "Done in #{(Time.now - start).round(1)}s"
    puts "  findings: #{stats[:findings]}"
    puts "  repaired: #{stats[:repaired]}"
    puts "  failed: #{stats[:failed]}"
    puts "  skipped (no core): #{stats[:skipped_no_core]}"
    puts "  tables redownloaded: #{stats[:tables_redownloaded]}"
    puts "  archives updated: #{stats[:archives_updated]}"
    puts "  organisms reloaded: #{stats[:organisms_reloaded]}"
    puts "  gene sets reloaded: #{stats[:gene_sets_reloaded]}"
    if stats[:repaired_db_names]&.any?
      puts "  organisms: #{stats[:repaired_db_names].join(', ')}"
    end
  end
end
