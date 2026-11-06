# frozen_string_literal: true

require "fileutils"
require "open-uri"
require "set"

module NcbiTaxonomyLoader
  module_function

  TAXDUMP_DEFAULT_URL = "https://ftp.ncbi.nlm.nih.gov/pub/taxonomy/taxdump.tar.gz"

  # Directory for taxdump + extracted dmp files.
  # NCBI_TAXONOMY_DATA_DIR overrides; otherwise PROD_DATA_DIR/ncbi_taxonomy, then DATA_DIR/ncbi_taxonomy.
  # No under-Rails tmp fallback: unset env would hide misconfiguration. Recreate the website container after .env changes.
  def taxonomy_cache_dir
    explicit = ENV["NCBI_TAXONOMY_DATA_DIR"].to_s.strip
    return explicit if explicit.present?

    prod = ENV["PROD_DATA_DIR"].to_s.strip
    return File.join(prod, "ncbi_taxonomy") if prod.present?

    data_dir = ENV["DATA_DIR"].to_s.strip
    return File.join(data_dir, "ncbi_taxonomy") if data_dir.present?

    raise ArgumentError,
          "Set PROD_DATA_DIR, DATA_DIR, or NCBI_TAXONOMY_DATA_DIR for ncbi_taxonomy cache (not using Rails tmp). " \
          "If .env was updated, recreate the container: docker compose -f docker-compose.test.yml up -d --force-recreate website"
  end

  def nodes_dmp_path
    env_path = ENV["NODES_DMP_PATH"].to_s.strip
    return env_path if env_path.present?

    File.join(taxonomy_cache_dir, "nodes.dmp")
  end

  def names_dmp_path
    env_path = ENV["NAMES_DMP_PATH"].to_s.strip
    return env_path if env_path.present?

    File.join(taxonomy_cache_dir, "names.dmp")
  end

  def taxdump_url
    ENV["TAXDUMP_URL"].to_s.strip.presence || TAXDUMP_DEFAULT_URL
  end

  # Downloads NCBI taxdump.tar.gz and extracts nodes.dmp + names.dmp next to nodes_dmp_path.
  # Skip with SKIP_DOWNLOAD=1 (files must exist). Re-fetch with FORCE_DOWNLOAD=1.
  def ensure_taxdump_files!
    nodes_path = nodes_dmp_path
    names_path = names_dmp_path
    dir = File.dirname(nodes_path)

    if ENV["SKIP_DOWNLOAD"].to_s == "1"
      raise ArgumentError, "nodes.dmp missing at #{nodes_path}" unless File.exist?(nodes_path)

      return
    end

    force = ENV["FORCE_DOWNLOAD"].to_s == "1"
    need = force || !File.exist?(nodes_path) || !File.exist?(names_path)

    unless need
      puts "[ncbi_taxonomy] using existing nodes.dmp / names.dmp in #{dir}"
      return
    end

    FileUtils.mkdir_p(dir)

    url = taxdump_url
    tarball = File.join(dir, "taxdump.tar.gz")

    puts "[ncbi_taxonomy] downloading #{url}"
    puts "[ncbi_taxonomy] -> #{tarball}"

    URI.open(url, read_timeout: 600, open_timeout: 120) do |remote|
      File.open(tarball, "wb") do |local|
        IO.copy_stream(remote, local)
      end
    end

    ok = system("tar", "-xzf", tarball, "-C", dir, "nodes.dmp", "names.dmp")
    raise "tar extract failed (nodes.dmp, names.dmp from taxdump.tar.gz)" unless ok

    raise ArgumentError, "extracted nodes.dmp missing at #{nodes_path}" unless File.exist?(nodes_path)

    FileUtils.rm_f(tarball) unless ENV["KEEP_TAXDUMP_TAR"].to_s == "1"

    puts "[ncbi_taxonomy] extracted nodes.dmp and names.dmp into #{dir}"
  end

  # Returns tax_id => { parent_tax_id:, rank: }
  def parse_nodes_file!(path)
    raise ArgumentError, "nodes.dmp not found at #{path}" unless File.exist?(path)

    node_by_tax_id = {}
    File.foreach(path) do |line|
      next if line.to_s.strip.empty?

      parts = line.split("|").map { |value| value.to_s.strip }
      tax_id = parts[0].to_i
      parent_tax_id = parts[1].to_i
      rank = parts[2].to_s
      next unless tax_id.positive?

      node_by_tax_id[tax_id] = {
        parent_tax_id: parent_tax_id.positive? ? parent_tax_id : nil,
        rank: rank
      }
    end

    raise ArgumentError, "No taxonomy rows parsed from #{path}" if node_by_tax_id.empty?

    node_by_tax_id
  end

  # Scientific names (NCBI names.dmp; name class "scientific name"). tax_id_set nil = all tax_ids.
  def parse_names_file!(path, tax_id_set)
    return {} unless path.present? && File.exist?(path)

    names = {}
    File.foreach(path) do |line|
      next if line.to_s.strip.empty?

      parts = line.split("|").map { |value| value.to_s.strip }
      tax_id = parts[0].to_i
      next if tax_id_set && !tax_id_set.include?(tax_id)

      name_txt = parts[1].to_s
      name_class = parts[3].to_s
      next unless name_class == "scientific name"
      next if name_txt.empty?

      names[tax_id] = name_txt unless names.key?(tax_id)
    end
    names
  end

  # Pick latest asap_data_* shard by numeric suffix (v8 > v6). Override with ASAP_DATA_DB_NAME.
  def source_asap_data_db_name
    known = Asap2RemoteRecord.remote_versions
    explicit = ENV["ASAP_DATA_DB_NAME"].to_s.strip
    return explicit if explicit.present? && known.include?(explicit)

    known.max_by { |name| name[/v(\d+)\z/, 1].to_i }
  end

  def organism_tax_ids_from_asap_data(db_name)
    raise ArgumentError, "Unknown asap_data database #{db_name}" unless Asap2RemoteRecord.remote_versions.include?(db_name.to_s)

    RemoteOrganism.with_remote(db_name) do
      RemoteOrganism.where.not(tax_id: nil).distinct.pluck(:tax_id).map(&:to_i).select(&:positive?).uniq
    end
  end

  def selected_tax_ids(node_by_tax_id, seeds)
    raise ArgumentError, "No seed tax_ids" if seeds.empty?

    selected = Set.new
    seeds.each do |seed_tax_id|
      current = seed_tax_id
      while current.to_i.positive? && !selected.include?(current)
        selected << current
        info = node_by_tax_id[current]
        break unless info

        parent = info[:parent_tax_id]
        break if parent.nil? || parent == current

        current = parent
      end
    end
    selected
  end

  # order_tax_id for every tax_id in tax_ids, memoized along shared lineages (fast for the full taxonomy).
  def order_tax_ids_for(tax_ids, node_by_tax_id)
    rank_order = NcbiTaxonomyNode::ORDER_RANK
    memo = {}
    tax_ids.each do |tax_id|
      path = []
      current = tax_id.to_i
      result = nil
      while current.positive?
        if memo.key?(current)
          result = memo[current]
          break
        end
        info = node_by_tax_id[current]
        break unless info

        path << current
        if info[:rank].to_s == rank_order
          result = current
          break
        end

        parent = info[:parent_tax_id]
        break if parent.nil? || parent == current || path.size > 500

        current = parent
      end
      # Every node on the walked path shares the result (no order node lies between them and it).
      path.each { |id| memo[id] = result }
    end
    memo
  end

  def upsert_rows!(rows)
    return if rows.empty?

    now = Time.current
    payload = rows.map do |row|
      {
        tax_id: row[:tax_id].to_i,
        parent_tax_id: row[:parent_tax_id],
        order_tax_id: row[:order_tax_id],
        rank: row[:rank].to_s,
        scientific_name: row[:scientific_name].to_s,
        created_at: now,
        updated_at: now
      }
    end

    # Do not list updated_at in update_only: Rails 8 record_timestamps adds it to ON CONFLICT SET and duplicates the column.
    NcbiTaxonomyNode.upsert_all(
      payload,
      unique_by: :tax_id,
      update_only: %i[parent_tax_id order_tax_id rank scientific_name]
    )
  end

  def prune!(keep_tax_ids)
    return 0 if keep_tax_ids.empty?

    keep = keep_tax_ids.map(&:to_i).to_set
    stale = NcbiTaxonomyNode.pluck(:tax_id).reject { |tax_id| keep.include?(tax_id) }
    stale.each_slice(10_000) { |slice| NcbiTaxonomyNode.where(tax_id: slice).delete_all }
    stale.size
  end
end

namespace :ncbi_taxonomy do
  desc "Load NCBI taxonomy into main DB (downloads taxdump.tar.gz unless SKIP_DOWNLOAD=1). Loads the full taxonomy by default " \
       "(needed to match any organism against clade-based CellOntology#tax_ids / rules.yaml organism maps); " \
       "SEEDED=1 keeps only asap_data organisms + ancestors. Env: PROD_DATA_DIR, DATA_DIR, NCBI_TAXONOMY_DATA_DIR, TAXDUMP_URL, " \
       "NODES_DMP_PATH, NAMES_DMP_PATH, SKIP_DOWNLOAD, FORCE_DOWNLOAD, KEEP_TAXDUMP_TAR, ASAP_DATA_DB_NAME, SEEDED=1, PRUNE=1"
  task load_nodes: :environment do
    NcbiTaxonomyLoader.ensure_taxdump_files!

    path = NcbiTaxonomyLoader.nodes_dmp_path
    names_path = NcbiTaxonomyLoader.names_dmp_path
    seeded = ENV["SEEDED"].to_s == "1"

    node_by_tax_id = NcbiTaxonomyLoader.parse_nodes_file!(path)
    puts "[ncbi_taxonomy:load_nodes] nodes_file=#{path} parsed_nodes=#{node_by_tax_id.size}"

    selected = if seeded
                 source_db = NcbiTaxonomyLoader.source_asap_data_db_name
                 raise ArgumentError, "Could not resolve source asap_data DB (check ASAP2_DATA_VERSIONS)" if source_db.blank?

                 seeds = NcbiTaxonomyLoader.organism_tax_ids_from_asap_data(source_db)
                 puts "[ncbi_taxonomy:load_nodes] SEEDED=1 source_asap_data=#{source_db} organism_distinct_tax_ids=#{seeds.size}"
                 NcbiTaxonomyLoader.selected_tax_ids(node_by_tax_id, seeds)
               else
                 node_by_tax_id.keys.to_set
               end

    names_by_id = NcbiTaxonomyLoader.parse_names_file!(names_path, seeded ? selected : nil)
    puts "[ncbi_taxonomy:load_nodes] names_file=#{names_path} (exists=#{File.exist?(names_path)}) names=#{names_by_id.size}"

    order_by_tax_id = NcbiTaxonomyLoader.order_tax_ids_for(selected, node_by_tax_id)

    loaded = 0
    selected.each_slice(10_000) do |slice|
      rows = slice.filter_map do |tax_id|
        info = node_by_tax_id[tax_id]
        next unless info

        {
          tax_id: tax_id,
          parent_tax_id: info[:parent_tax_id],
          order_tax_id: order_by_tax_id[tax_id],
          rank: info[:rank],
          scientific_name: names_by_id[tax_id].to_s
        }
      end
      NcbiTaxonomyLoader.upsert_rows!(rows)
      loaded += rows.size
    end
    puts "[ncbi_taxonomy:load_nodes] upserted_nodes=#{loaded} (#{seeded ? 'seeds + ancestors' : 'full taxonomy'})"

    missing = selected.reject { |tid| node_by_tax_id.key?(tid) }
    puts "[ncbi_taxonomy:load_nodes] WARNING tax_ids absent from nodes.dmp: #{missing.first(20).join(',')}" if missing.any?

    if ENV["PRUNE"] == "1"
      pruned = NcbiTaxonomyLoader.prune!(selected.to_a)
      puts "[ncbi_taxonomy:load_nodes] pruned_nodes=#{pruned}"
    end

    puts "[ncbi_taxonomy:load_nodes] ncbi_taxonomy_nodes rows=#{NcbiTaxonomyNode.count}"
  end
end
