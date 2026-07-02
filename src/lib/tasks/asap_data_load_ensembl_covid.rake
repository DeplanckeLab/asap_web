# frozen_string_literal: true

namespace :asap_data do
  desc "Load Ensembl COVID-19 (SARS-CoV-2) reference data from static viruses FTP dumps. ENV: ASAP2_REMOTE_DB, ENSEMBL_DATA_DIR, DOWNLOAD_COVID_FILES"
  task load_ensembl_covid: :environment do
    dev_null = Logger.new("/dev/null")
    Rails.logger = dev_null
    ActiveRecord::Base.logger = dev_null

    start = Time.now
    remote_db = ENV["ASAP2_REMOTE_DB"].presence || "asap_data_v8"
    base_dirs = AsapData::EnsemblAssembliesLoader.all_ensembl_base_dirs
    download = AsapData::EnsemblCovidLoader.default_download?

    puts "Load Ensembl COVID-19 reference data"
    puts "  ensembl data dirs: #{base_dirs.map(&:to_s).join(', ')}"
    puts "  remote db: #{remote_db}"
    puts "  download files: #{download}"
    puts "  release: #{AsapData::EnsemblCovidLoader::RELEASE}"
    puts

    stats = AsapData::EnsemblCovidLoader.populate!(remote_db: remote_db, download: download)

    elapsed = Time.now - start
    puts
    puts "Done in #{elapsed.round(1)}s"
    puts "  files cached: #{stats[:files_cached]}"
    puts "  genes parsed: #{stats[:genes_parsed]}"
    puts "  subdomain created: #{stats[:subdomain_created]}"
    puts "  organism created: #{stats[:organism_created]}"
    puts "  assembly created: #{stats[:assembly_created]}"
    puts "  genes created: #{stats[:genes_created]}"
    puts "  genes updated: #{stats[:genes_updated]}"
    puts "  genes unchanged: #{stats[:genes_unchanged]}"

    RemoteOrganism.with_remote(remote_db) do
      organism = RemoteOrganism.find_by(tax_id: AsapData::EnsemblCovidLoader::TAX_ID)
      if organism
        puts "  organism id: #{organism.id} (#{organism.ensembl_db_name})"
        puts "  genes in db: #{RemoteGene.where(organism_id: organism.id).count}"
        puts "  assemblies in db: #{RemoteAssembly.where(organism_id: organism.id).count}"
      end
    end
  end
end
