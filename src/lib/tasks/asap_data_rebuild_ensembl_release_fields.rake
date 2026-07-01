# frozen_string_literal: true

namespace :asap_data do
  desc "Run full Ensembl metadata rebuild: (1) meta/coord_system files, (2) assemblies + first_ensembl_release, (3) gene name/alt_names/obsolete_alt_names from Ensembl xrefs (all releases, matching update_genes). ENV: ASAP2_REMOTE_DB, ENSEMBL_DATA_DIR (default /mnt/asap_data/ensembl), ENSEMBL_MERGE_DATA_DIRS, SKIP_META_FILES, SKIP_ASSEMBLIES, SKIP_GENE_RELEASES, SKIP_NCBI_ALT_NAMES, ORGANISM_ID, EXCLUDE_ORGANISM_ID"
  task rebuild_ensembl_release_fields: :environment do
    dev_null = Logger.new("/dev/null")
    Rails.logger = dev_null
    ActiveRecord::Base.logger = dev_null

    remote_db = ENV["ASAP2_REMOTE_DB"].presence || "asap_data_v8"
    base_dirs = AsapData::EnsemblAssembliesLoader.all_ensembl_base_dirs
    pipeline_start = Time.now

    puts "Rebuild Ensembl release fields"
    puts "  remote db: #{remote_db}"
    puts "  ensembl data dirs: #{base_dirs.map(&:to_s).join(', ')}"
    puts "  vertebrates releases: 54-115"
    puts "  ensembl genomes releases: 5-62"
    puts

    unless env_skip?("SKIP_META_FILES")
      puts "== Step 1/3: complete meta.txt and coord_system.txt =="
      step_start = Time.now
      %w[vertebrates bacteria fungi metazoa plants protists].each do |db_type|
        with_env(
          "ENSEMBL_DB_TYPES" => db_type,
          "ENSEMBL_RELEASE_FROM" => db_type == "vertebrates" ? "54" : "5",
          "ENSEMBL_RELEASE_TO" => db_type == "vertebrates" ? "115" : "62"
        ) do
          stats = AsapData::EnsemblAssembliesLoader.complete_local_meta_files!(remote_db: remote_db)
          puts "  #{db_type}: checked=#{stats[:organisms_checked]} meta=#{stats[:meta_downloaded]} coord=#{stats[:coord_system_downloaded]} already=#{stats[:already_complete]} (#{(Time.now - step_start).round(1)}s)"
        end
      end
      puts
    end

    unless env_skip?("SKIP_ASSEMBLIES")
      puts "== Step 2a/3: populate assemblies =="
      step_start = Time.now
      AsapData::EnsemblAssembliesLoader.truncate_assemblies!(remote_db: remote_db)
      stats = AsapData::EnsemblAssembliesLoader.populate!(
        remote_db: remote_db,
        download_missing_meta: false
      )
      puts "  assemblies created=#{stats[:assemblies_created]} updated=#{stats[:assemblies_updated]} skipped_no_meta=#{stats[:skipped_no_meta]} (#{(Time.now - step_start).round(1)}s)"
      puts
    end

    unless env_skip?("SKIP_GENE_RELEASES")
      puts "== Step 2b/3: populate genes.first_ensembl_release =="
      $stdout.sync = true
      %w[vertebrates bacteria fungi metazoa plants protists].each do |db_type|
        step_start = Time.now
        with_env(
          "ENSEMBL_DB_TYPES" => db_type,
          "ENSEMBL_RELEASE_FROM" => db_type == "vertebrates" ? "54" : "5",
          "ENSEMBL_RELEASE_TO" => db_type == "vertebrates" ? "115" : "62"
        ) do
          stats = AsapData::GeneFirstEnsemblReleasePopulator.populate!(
            remote_db: remote_db,
            download_missing_gene_table: AsapData::GeneFirstEnsemblReleasePopulator.default_download_missing_gene_table?,
            force: AsapData::GeneFirstEnsemblReleasePopulator.default_force?
          )
          puts "  #{db_type}: updated=#{stats[:genes_updated]} latest_updated=#{stats[:latest_genes_updated]} processed=#{stats[:organisms_processed]} reads=#{stats[:gene_table_reads]} corrupt=#{stats[:corrupt_gene_table_reads]} (#{(Time.now - step_start).round(1)}s)"
        end
      end
      puts
    end

    unless env_skip?("SKIP_NCBI_ALT_NAMES")
      puts "== Step 3/3: rebuild genes.name, alt_names, obsolete_alt_names from Ensembl xrefs =="
      $stdout.sync = true
      step_start = Time.now
      stats = AsapData::GeneNcbiAltNamesPopulator.populate!(
        remote_db: remote_db,
        download_missing_tables: false
      )
      puts "  genes updated=#{stats[:genes_updated]} unchanged=#{stats[:genes_unchanged]} organisms=#{stats[:organisms_processed]} releases=#{stats[:releases_applied]} skipped_releases=#{stats[:releases_skipped]} table_reads=#{stats[:table_reads]} (#{(Time.now - step_start).round(1)}s)"
      puts
    end

    puts "Pipeline done in #{(Time.now - pipeline_start).round(1)}s"
  end

  def env_skip?(name)
    ENV.fetch(name, "false").to_s.strip.downcase == "true"
  end

  def with_env(overrides)
    previous = overrides.keys.index_with { |key| ENV[key] }
    overrides.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each do |key, value|
      if value.nil?
        ENV.delete(key)
      else
        ENV[key] = value
      end
    end
  end
end
