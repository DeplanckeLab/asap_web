# frozen_string_literal: true

namespace :asap_data do
  desc <<~DESC.gsub(/\s+/, " ").strip
    Backfill genes.first_ensembl_release where NULL by scanning Ensembl releases
    oldest->newest (downloads gene_stable_id/gene.txt for early schemas when needed).
    Default MODE=scan, DOWNLOAD_MISSING_GENE_TABLE=true.
    ENV: ASAP2_REMOTE_DB, ENSEMBL_DATA_DIR, ORGANISM, ORGANISM_ID,
    DOWNLOAD_MISSING_GENE_TABLE, MODE=scan|approximate|scan_then_approximate
  DESC
  task backfill_missing_gene_first_ensembl_release: :environment do
    Rails.logger = Logger.new("/dev/null")
    ActiveRecord::Base.logger = Logger.new("/dev/null")

    start = Time.now
    remote_db = AsapData::GeneFirstEnsemblReleaseBackfill.default_remote_db
    download_missing = AsapData::GeneFirstEnsemblReleaseBackfill.default_download_missing_gene_table?
    mode = AsapData::GeneFirstEnsemblReleaseBackfill.default_mode
    base_dirs = AsapData::EnsemblAssembliesLoader.all_ensembl_base_dirs

    puts "Backfill genes.first_ensembl_release (NULL only)"
    puts "  ensembl data dirs: #{base_dirs.map(&:to_s).join(', ')}"
    puts "  remote db: #{remote_db}"
    puts "  mode: #{mode}"
    puts "  download missing gene tables: #{download_missing}"
    puts

    stats = AsapData::GeneFirstEnsemblReleaseBackfill.backfill!(
      remote_db: remote_db,
      download_missing_gene_table: download_missing,
      mode: mode
    )

    elapsed = Time.now - start
    puts
    puts "Done in #{elapsed.round(1)}s"
    puts "  organisms total: #{stats[:organisms_total]}"
    puts "  organisms processed: #{stats[:organisms_processed]}"
    puts "  organisms skipped: #{stats[:organisms_skipped]}"
    puts "  genes updated from scan: #{stats[:genes_updated_from_scan]}"
    puts "  genes updated from approximate: #{stats[:genes_updated_from_approximate]}"
    puts "  releases scanned: #{stats[:releases_scanned]}"
    puts "  releases skipped (early exit): #{stats[:releases_skipped_early_exit]}"
    puts "  gene table reads: #{stats[:gene_table_reads]}"
    puts "  gene table downloads: #{stats[:gene_table_downloads]}"
    puts "  genes still missing first_ensembl_release: #{stats[:genes_still_missing]}"
  end
end
