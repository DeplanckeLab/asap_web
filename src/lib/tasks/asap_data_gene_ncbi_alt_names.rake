# frozen_string_literal: true

namespace :asap_data do
  desc "Add NCBI gene symbols to genes.alt_names from local Ensembl xref.txt (one release per organism). ENV: ASAP2_REMOTE_DB, ENSEMBL_DATA_DIR, ENSEMBL_DB_TYPES, ORGANISM_ID, DOWNLOAD_MISSING_TABLES"
  task populate_gene_ncbi_alt_names: :environment do
    dev_null = Logger.new("/dev/null")
    Rails.logger = dev_null
    ActiveRecord::Base.logger = dev_null

    start = Time.now
    remote_db = ENV["ASAP2_REMOTE_DB"].presence || "asap_data_v8"
    base_dirs = AsapData::EnsemblAssembliesLoader.all_ensembl_base_dirs
    download_missing_tables = AsapData::GeneNcbiAltNamesPopulator.default_download_missing_tables?

    puts "Populate genes.alt_names with NCBI gene symbols"
    puts "  ensembl data dirs: #{base_dirs.map(&:to_s).join(', ')}"
    puts "  remote db: #{remote_db}"
    puts "  download missing xref tables: #{download_missing_tables}"
    puts

    stats = AsapData::GeneNcbiAltNamesPopulator.populate!(
      remote_db: remote_db,
      download_missing_tables: download_missing_tables
    )

    elapsed = Time.now - start
    puts
    puts "Done in #{elapsed.round(1)}s"
    puts "  organisms total: #{stats[:organisms_total]}"
    puts "  organisms processed: #{stats[:organisms_processed]}"
    puts "  organisms skipped: #{stats[:organisms_skipped]}"
    puts "  genes updated: #{stats[:genes_updated]}"
    puts "  genes unchanged: #{stats[:genes_unchanged]}"
    puts "  genes without NCBI xref: #{stats[:genes_without_ncbi_name]}"
    puts "  table reads: #{stats[:table_reads]}"
    puts "  table downloads: #{stats[:table_downloads]}"
  end
end
