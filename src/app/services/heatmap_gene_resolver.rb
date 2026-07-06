# frozen_string_literal: true

# Resolves a selected gene set item (global reference, imported/local, or manual)
# into a plain list of gene identifiers ({ symbol:, ensembl_id: }).
#
# The heatmap compute script (heatmap.v8.py) matches these identifiers against
# the loom's own gene metadata, so we deliberately do NOT map to dataset stable
# indices here. This keeps resolution independent of the loom file and reusable
# from the run-submission path (Basic.set_run).
class HeatmapGeneResolver
  LOCAL_PREFIX = "local_collection"
  MANUAL_PREFIX = "manual_local"

  Result = Struct.new(:genes, :warnings, keyword_init: true)

  def self.resolve(project:, item_id:, collection_id: nil)
    new(project: project, item_id: item_id, collection_id: collection_id).resolve
  end

  def initialize(project:, item_id:, collection_id: nil)
    @project = project
    @item_id = item_id.to_s.strip
    @collection_id = collection_id.to_s.strip
  end

  def resolve
    return empty("Missing gene set item identifier") if @item_id.blank?

    if (local_collection_db_id = parse_local_collection_db_id(@item_id))
      resolve_local(local_collection_db_id)
    elsif @item_id.start_with?("#{MANUAL_PREFIX}:")
      resolve_manual
    elsif @item_id.to_i.positive?
      resolve_global(@item_id.to_i)
    else
      empty("Unrecognized gene set item identifier: #{@item_id}")
    end
  end

  private

  def empty(warning)
    Result.new(genes: [], warnings: [warning].compact)
  end

  def gene_set_collections_dir
    user_data_dir = ENV["USER_DATA_DIR"] || Rails.root.join("storage", "user_data").to_s
    Pathname.new(user_data_dir) + @project.user_id.to_s + @project.key + "gene_set_collections"
  end

  def parse_local_collection_db_id(item_id)
    m = item_id.match(/\A#{Regexp.escape(LOCAL_PREFIX)}:(\d+):/)
    m ? m[1].to_i : nil
  end

  def read_collection_items(file_key)
    return [] if file_key.to_s.strip.empty?
    return [] unless file_key.match?(/\A[a-zA-Z0-9_-]+\z/)

    path = gene_set_collections_dir + "#{file_key}.json"
    return [] unless File.exist?(path)

    parsed = Basic.safe_parse_json(File.read(path), {})
    return [] unless parsed.is_a?(Hash)

    Array(parsed["items"])
  end

  def genes_from_item(item)
    return [] unless item.is_a?(Hash)

    Array(item["genes"]).filter_map do |gene|
      next unless gene.is_a?(Hash)
      symbol = gene["symbol"].to_s.strip
      ensembl = gene["ensembl_id"].to_s.strip
      next if symbol.empty? && ensembl.empty?
      { symbol: symbol, ensembl_id: ensembl }
    end
  end

  def resolve_local(collection_db_id)
    collection = GeneSetCollection.find_by(id: collection_db_id, project_id: @project.id)
    return empty("Gene set collection not found") unless collection

    items = read_collection_items(collection.file_key)
    item = items.find { |it| it.is_a?(Hash) && it["id"].to_s == @item_id }
    return empty("Gene set not found in collection") unless item

    genes = genes_from_item(item)
    genes.empty? ? empty("Selected gene set has no genes") : Result.new(genes: genes, warnings: [])
  end

  def resolve_manual
    path = gene_set_collections_dir + "manual_gene_sets.json"
    return empty("Manual gene sets not found") unless File.exist?(path)

    parsed = Basic.safe_parse_json(File.read(path), {})
    items = parsed.is_a?(Hash) ? Array(parsed["items"]) : []
    item = items.find { |it| it.is_a?(Hash) && it["id"].to_s == @item_id }
    return empty("Manual gene set not found") unless item

    genes = genes_from_item(item)
    genes.empty? ? empty("Selected gene set has no genes") : Result.new(genes: genes, warnings: [])
  end

  def resolve_global(item_id)
    h_env = Basic.safe_parse_json(@project.version.env_json, {})
    db_version = Basic.asap_data_db_name_from_env!(h_env)

    genes = []
    RemoteGene.with_remote(db_version, role: :reading) do
      conn = RemoteGene.connection
      item_row = conn.select_one("SELECT content FROM gene_set_items WHERE id = #{item_id.to_i}")
      return empty("Global gene set not found") unless item_row

      gene_ids = item_row["content"].to_s.split(",").map(&:to_i).select { |v| v > 0 }
      return empty("Global gene set is empty") if gene_ids.empty?

      rows = conn.select_all(
        "SELECT name, ensembl_id FROM genes WHERE id IN (#{gene_ids.map(&:to_i).join(',')})"
      )
      genes = rows.map do |row|
        { symbol: row["name"].to_s.strip, ensembl_id: row["ensembl_id"].to_s.strip }
      end.reject { |g| g[:symbol].empty? && g[:ensembl_id].empty? }
    end

    genes.empty? ? empty("Could not resolve any genes for the global gene set") : Result.new(genes: genes, warnings: [])
  rescue StandardError => e
    Rails.logger.error("[HeatmapGeneResolver] global resolve failed: #{e.class} - #{e.message}")
    empty("Failed to resolve global gene set: #{e.message}")
  end
end
