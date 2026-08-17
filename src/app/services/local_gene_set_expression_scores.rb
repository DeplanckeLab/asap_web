# frozen_string_literal: true

require 'set'

class LocalGeneSetExpressionScores
  LOCAL_COLLECTION_PREFIX = 'local_collection'
  MANUAL_COLLECTION_ID = 'manual_local'

  def initialize(project)
    @project = project
  end

  def call(item_id_raw:, loom_path:, dataset_path:)
    item = find_local_or_manual_gene_set_item(item_id_raw)
    raise ArgumentError, 'Gene set item not found' unless item

    dataset_lookup = dataset_stable_lookup(loom_path)
    stable_ids = Array(item[:genes]).filter_map do |gene|
      resolve_manual_gene_stable_id(
        gene,
        dataset_stable_by_accession: dataset_lookup[:by_accession],
        dataset_stable_by_symbol: dataset_lookup[:by_symbol],
        dataset_stable_ids: dataset_lookup[:stable_ids]
      )
    end.uniq
    raise ArgumentError, 'No genes from this gene set are present in the dataset' if stable_ids.empty?

    stable_id_vector = H5DataService.get_metadata_vector(loom_path.to_s, '/row_attrs/_StableID')
    raise ArgumentError, 'Failed to read gene stable IDs from loom' unless stable_id_vector.is_a?(Array) && stable_id_vector.any?

    wanted = {}
    stable_ids.each { |sid| wanted[sid.to_s] = true }
    row_indexes = []
    stable_id_vector.each_with_index do |value, idx|
      key = value.to_s.strip
      row_indexes << idx if wanted[key]
    end
    raise ArgumentError, 'No matching gene rows found in the loom for this gene set' if row_indexes.empty?

    sums = nil
    gene_count = 0
    row_indexes.each_slice(50) do |slice|
      extracted = H5DataService.extract_row_by_indexes(loom_path.to_s, dataset_path, slice)
      rows = extracted['rows'] || extracted['values'] || []
      rows.each do |row|
        next unless row.is_a?(Array)

        gene_count += 1
        if sums.nil?
          sums = row.map(&:to_f)
        else
          row.each_with_index { |v, i| sums[i] = sums[i].to_f + v.to_f }
        end
      end
    end
    raise ArgumentError, 'Failed to extract expression values for gene set' if sums.nil? || gene_count <= 0

    sums.map { |total| total.to_f / gene_count }
  end

  private

  def find_local_or_manual_gene_set_item(item_id_raw)
    local_collection_id = parse_local_collection_id_from_item_id(item_id_raw)
    if local_collection_id
      local_collection = GeneSetCollection.find_by(id: local_collection_id, project_id: @project.id)
      return nil unless local_collection

      payload = load_collection_payload(local_collection.file_key, local_collection.name)
      return Array(payload['items']).map { |item| normalize_item(item) }.compact.find do |item|
        item[:id].to_s == item_id_raw
      end
    end

    return find_manual_item(item_id_raw) if item_id_raw.start_with?("#{MANUAL_COLLECTION_ID}:")

    nil
  end

  def parse_local_collection_id_from_item_id(item_id)
    match = item_id.to_s.strip.match(/\A#{Regexp.escape(LOCAL_COLLECTION_PREFIX)}:(\d+):/)
    match ? match[1].to_i : nil
  end

  def find_manual_item(item_id)
    payload = load_payload_file(collections_dir + 'manual_gene_sets.json', 'Manual Gene Sets')
    Array(payload['items']).each do |raw_item|
      normalized = normalize_item(raw_item)
      next unless normalized
      return normalized if normalized[:id].to_s == item_id.to_s
    end
    nil
  end

  def load_collection_payload(file_key, collection_label)
    path = collections_dir + "#{file_key}.json"
    load_payload_file(path, collection_label)
  end

  def load_payload_file(path, collection_label)
    return { 'collection' => collection_label.to_s, 'items' => [] } unless File.exist?(path)

    parsed = Basic.safe_parse_json(File.read(path), {})
    parsed = {} unless parsed.is_a?(Hash)
    parsed['collection'] = collection_label.to_s
    parsed['items'] = Array(parsed['items'])
    parsed
  end

  def collections_dir
    @project.data_dir + 'gene_set_collections'
  end

  def normalize_item(raw_item)
    return nil unless raw_item.is_a?(Hash)

    item_id = raw_item['id'].to_s.strip
    item_identifier = raw_item['identifier'].to_s.strip
    item_name = raw_item['name'].to_s.strip
    return nil if item_id.blank? && item_identifier.blank?

    item_id = "#{MANUAL_COLLECTION_ID}:#{item_identifier}" if item_id.blank?
    genes = Array(raw_item['genes']).filter_map do |gene|
      next unless gene.is_a?(Hash)

      symbol = gene['symbol'].to_s.strip
      ensembl_id = gene['ensembl_id'].to_s.strip
      stable_id = gene['stable_id'].to_s.strip
      next if symbol.blank? && ensembl_id.blank? && stable_id.blank?

      {
        symbol: symbol,
        ensembl_id: ensembl_id,
        stable_id: stable_id,
        gene_id: gene['gene_id'].to_i > 0 ? gene['gene_id'].to_i : nil
      }
    end
    {
      id: item_id,
      identifier: item_identifier,
      name: item_name,
      genes: genes
    }
  end

  def dataset_stable_lookup(loom_path)
    autocomplete_file = loom_path.dirname + 'autocomplete_genes.json'
    parsed = AsapData::DatasetStableLookup.from_autocomplete_json_file(autocomplete_file.to_s)
    return parsed.merge(source: :autocomplete_json) if parsed

    stable_values = H5DataService.get_metadata_vector(loom_path.to_s, '/row_attrs/_StableID')
    accession_values = H5DataService.get_metadata_vector(loom_path.to_s, '/row_attrs/Accession')
    gene_values = H5DataService.get_metadata_vector(loom_path.to_s, '/row_attrs/Gene')
    size = [stable_values.length, accession_values.length, gene_values.length].min
    by_accession = {}
    by_symbol = {}
    stable_ids = Set.new

    size.times do |idx|
      stable_id = stable_values[idx].to_s.strip
      next if stable_id.blank?

      stable_ids.add(stable_id)
      accession = accession_values[idx].to_s.strip.downcase
      symbol = gene_values[idx].to_s.strip.downcase
      by_accession[accession] ||= stable_id if accession.present?
      by_symbol[symbol] ||= stable_id if symbol.present?
    end

    { by_accession: by_accession, by_symbol: by_symbol, stable_ids: stable_ids, source: :extract_metadata }
  end

  def resolve_manual_gene_stable_id(gene, dataset_stable_by_accession:, dataset_stable_by_symbol:, dataset_stable_ids:)
    return nil unless gene.is_a?(Hash)

    symbol = gene[:symbol].to_s.strip
    ensembl_id = gene[:ensembl_id].to_s.strip
    stable_id = gene[:stable_id].to_s.strip
    return stable_id if stable_id.present? && dataset_stable_ids.include?(stable_id)

    selected = dataset_stable_by_accession[ensembl_id.downcase] if ensembl_id.present?
    selected ||= dataset_stable_by_symbol[symbol.downcase] if symbol.present?
    selected.presence
  end
end
