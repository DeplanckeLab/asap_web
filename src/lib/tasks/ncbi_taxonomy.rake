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

  # Scientific names for tax_ids in set only (NCBI names.dmp; name class "scientific name").
  def parse_names_file!(path, tax_id_set)
    return {} unless path.present? && File.exist?(path)

    names = {}
    File.foreach(path) do |line|
      next if line.to_s.strip.empty?

      parts = line.split("|").map { |value| value.to_s.strip }
      tax_id = parts[0].to_i
      next unless tax_id_set.include?(tax_id)

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

  # First ancestor (including self) with rank "order" when walking toward root; nil if none (e.g. above order).
  def order_tax_id_from_map(tax_id, node_by_tax_id)
    rank_order = NcbiTaxonomyNode::ORDER_RANK
    seen = Set.new
    current = tax_id.to_i
    while current.positive?
      break if seen.include?(current)

      seen << current
      info = node_by_tax_id[current]
      return nil unless info

      return current if info[:rank].to_s == rank_order

      parent = info[:parent_tax_id]
      break if parent.nil? || parent == current

      current = parent
    end
    nil
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
    return if keep_tax_ids.empty?

    keep = keep_tax_ids.map(&:to_i).to_set
    NcbiTaxonomyNode.where.not(tax_id: keep.to_a).delete_all
  end
end

namespace :ncbi_taxonomy do
  desc "Load NCBI taxonomy into main DB (downloads taxdump.tar.gz unless SKIP_DOWNLOAD=1). Env: PROD_DATA_DIR, DATA_DIR, NCBI_TAXONOMY_DATA_DIR, TAXDUMP_URL, NODES_DMP_PATH, NAMES_DMP_PATH, SKIP_DOWNLOAD, FORCE_DOWNLOAD, KEEP_TAXDUMP_TAR, ASAP_DATA_DB_NAME, PRUNE=1"
  task load_nodes: :environment do
    NcbiTaxonomyLoader.ensure_taxdump_files!

    path = NcbiTaxonomyLoader.nodes_dmp_path
    names_path = NcbiTaxonomyLoader.names_dmp_path
    source_db = NcbiTaxonomyLoader.source_asap_data_db_name
    raise ArgumentError, "Could not resolve source asap_data DB (check ASAP2_DATA_VERSIONS)" if source_db.blank?

    node_by_tax_id = NcbiTaxonomyLoader.parse_nodes_file!(path)
    seeds = NcbiTaxonomyLoader.organism_tax_ids_from_asap_data(source_db)
    selected = NcbiTaxonomyLoader.selected_tax_ids(node_by_tax_id, seeds)
    names_by_id = NcbiTaxonomyLoader.parse_names_file!(names_path, selected)

    rows = selected.filter_map do |tax_id|
      info = node_by_tax_id[tax_id]
      next unless info

      {
        tax_id: tax_id,
        parent_tax_id: info[:parent_tax_id],
        order_tax_id: NcbiTaxonomyLoader.order_tax_id_from_map(tax_id, node_by_tax_id),
        rank: info[:rank],
        scientific_name: names_by_id[tax_id].to_s
      }
    end

    puts "[ncbi_taxonomy:load_nodes] nodes_file=#{path}"
    puts "[ncbi_taxonomy:load_nodes] names_file=#{names_path} (exists=#{File.exist?(names_path)})"
    puts "[ncbi_taxonomy:load_nodes] source_asap_data=#{source_db} organism_distinct_tax_ids=#{seeds.size}"
    puts "[ncbi_taxonomy:load_nodes] selected_nodes=#{rows.size} (seeds + ancestors)"

    NcbiTaxonomyLoader.upsert_rows!(rows)

    missing = selected.reject { |tid| node_by_tax_id.key?(tid) }
    puts "[ncbi_taxonomy:load_nodes] WARNING tax_ids absent from nodes.dmp: #{missing.first(20).join(',')}" if missing.any?

    NcbiTaxonomyLoader.prune!(selected.to_a) if ENV["PRUNE"] == "1"

    puts "[ncbi_taxonomy:load_nodes] ncbi_taxonomy_nodes rows=#{NcbiTaxonomyNode.count}"
  end
end
