# frozen_string_literal: true

namespace :asap_data do
  desc "Populate genes.first_ensembl_release from local Ensembl gene.txt (organism by organism). ENV: ASAP2_REMOTE_DB, ENSEMBL_DATA_DIR, ENSEMBL_DB_TYPES, ENSEMBL_RELEASE_FROM (default: 54 vertebrates, 1 ensembl genomes), ENSEMBL_RELEASE_TO (default: organism/subdomain latest or 115), ORGANISM_ID, DOWNLOAD_MISSING_GENE_TABLE, FORCE"
  task populate_gene_first_ensembl_release: :environment do
    dev_null = Logger.new("/dev/null")
    Rails.logger = dev_null
    ActiveRecord::Base.logger = dev_null

    start = Time.now
    remote_db = ENV["ASAP2_REMOTE_DB"].presence || "asap_data_v8"
    base_dirs = AsapData::EnsemblAssembliesLoader.all_ensembl_base_dirs
    download_missing_gene_table = AsapData::GeneFirstEnsemblReleasePopulator.default_download_missing_gene_table?
    force = AsapData::GeneFirstEnsemblReleasePopulator.default_force?

    puts "Populate genes.first_ensembl_release"
    puts "  ensembl data dirs: #{base_dirs.map(&:to_s).join(', ')}"
    puts "  remote db: #{remote_db}"
    puts "  download missing gene.txt: #{download_missing_gene_table}"
    puts "  force update: #{force}"
    puts

    stats = AsapData::GeneFirstEnsemblReleasePopulator.populate!(
      remote_db: remote_db,
      download_missing_gene_table: download_missing_gene_table,
      force: force
    )

    elapsed = Time.now - start
    puts
    puts "Done in #{elapsed.round(1)}s"
    puts "  organisms total: #{stats[:organisms_total]}"
    puts "  organisms processed: #{stats[:organisms_processed]}"
    puts "  organisms skipped: #{stats[:organisms_skipped]}"
    puts "  genes updated: #{stats[:genes_updated]}"
    puts "  genes unchanged: #{stats[:genes_unchanged]}"
    puts "  genes without ensembl match: #{stats[:genes_without_match]}"
    puts "  gene.txt reads: #{stats[:gene_table_reads]}"
    puts "  corrupt gene.txt reads: #{stats[:corrupt_gene_table_reads]}"
    puts "  gene.txt downloads: #{stats[:gene_table_downloads]}"

    RemoteGene.with_remote(remote_db) do
      missing = RemoteGene.where(first_ensembl_release: nil).count
      puts "  genes still missing first_ensembl_release: #{missing}"
    end
  end
end
