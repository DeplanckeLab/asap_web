class GeneSetCollectionImportJob < ApplicationJob
  queue_as :default

  def perform(project_id, collection_id, upload_file_path, import_id, loom_file)
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    log_import(:info, 'start', project_id: project_id, collection_id: collection_id, import_id: import_id)

    project = Project.find_by(id: project_id)
    unless project
      broadcast_failed(project_id, import_id, 'Project not found')
      return
    end
    collection_record = GeneSetCollection.find_by(id: collection_id, project_id: project.id)
    unless collection_record
      broadcast_failed(project.id, import_id, 'Gene set collection not found')
      return
    end

    unless upload_file_path.present? && File.exist?(upload_file_path)
      cleanup_failed_collection(project.id, collection_record.id)
      broadcast_failed(project.id, import_id, 'Uploaded file is missing', collection_id: collection_record.id)
      return
    end
    file_content = File.read(upload_file_path).to_s
    log_import(:info, 'file_loaded', project_id: project.id, collection_id: collection_record.id, bytes: file_content.bytesize)
    if file_content.blank?
      cleanup_failed_collection(project.id, collection_record.id)
      broadcast_failed(project.id, import_id, 'Uploaded file is empty', collection_id: collection_record.id)
      return
    end

    parsed_items = parse_uploaded_gene_set_collection_items!(collection_record.source_kind.to_s, file_content)
    parsed_gene_count = parsed_items.sum { |item| Array(item[:genes]).length }
    log_import(
      :info,
      'parsed_items',
      project_id: project.id,
      collection_id: collection_record.id,
      source_kind: collection_record.source_kind.to_s,
      items: parsed_items.length,
      genes: parsed_gene_count
    )
    if parsed_items.empty?
      cleanup_failed_collection(project.id, collection_record.id)
      broadcast_failed(project.id, import_id, 'No gene sets found in uploaded file', collection_id: collection_record.id)
      return
    end

    h_env = Basic.safe_parse_json(project.version&.env_json, {})
    db_version = "asap2_data_v#{h_env['asap_data_db_version']}"
    dataset_stable_by_accession, dataset_stable_by_symbol = build_dataset_stable_lookup(project, loom_file)
    timestamp = Time.now.utc.iso8601
    normalized_items = []

    GeneSetCollection.transaction do
      normalized_items = normalize_uploaded_collection_items_for_storage(
        parsed_items,
        db_version: db_version,
        collection_id: "local_collection:#{collection_record.id}",
        timestamp: timestamp,
        resolve_gene_ids: true,
        organism_id: project.organism_id,
        dataset_stable_by_accession: dataset_stable_by_accession,
        dataset_stable_by_symbol: dataset_stable_by_symbol
      )

      payload = {
        'collection' => collection_record.name.to_s,
        'source_kind' => collection_record.source_kind.to_s,
        'items' => normalized_items,
        'created_at' => timestamp,
        'updated_at' => timestamp
      }
      write_local_gene_set_collection_payload(project, collection_record.file_key, payload)
    end

    normalized_gene_count = normalized_items.sum { |item| Array(item['genes']).length }
    resolved_gene_count = normalized_items.sum { |item| Array(item['genes']).count { |gene| gene[:gene_id].present? || gene['gene_id'].present? } }
    log_import(
      :info,
      'completed',
      project_id: project.id,
      collection_id: collection_record.id,
      import_id: import_id,
      items: normalized_items.length,
      genes: normalized_gene_count,
      resolved_genes: resolved_gene_count,
      duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
    )

    ActionCable.server.broadcast("project_#{project.id}", {
      event: 'gene_set_collection_import',
      status: 'completed',
      import_id: import_id,
      collection: {
        id: "local_collection:#{collection_record.id}",
        label: collection_record.name.to_s,
        nb_items: normalized_items.length,
        custom: true,
        type_key: collection_record.gene_set_collection_type&.key.to_s.presence || 'imported',
        type_label: collection_record.gene_set_collection_type&.label.to_s.presence || 'Imported',
        type_icon: collection_record.gene_set_collection_type&.icon.to_s.presence || 'fas fa-file-import',
        type_icon_color: collection_record.gene_set_collection_type&.icon_color.to_s.presence || '#6b7280'
      }
    })
  rescue JSON::ParserError => e
    log_import(:error, 'json_parse_error', project_id: project_id, collection_id: collection_id, import_id: import_id, error: e.message)
    cleanup_failed_collection(project_id, collection_id)
    broadcast_failed(project_id, import_id, "Invalid JSON format: #{e.message}", collection_id: collection_id)
  rescue StandardError => e
    log_import(
      :error,
      'standard_error',
      project_id: project_id,
      collection_id: collection_id,
      import_id: import_id,
      error_class: e.class.name,
      error: e.message,
      backtrace: Array(e.backtrace).first(5).join(' | ')
    )
    cleanup_failed_collection(project_id, collection_id)
    broadcast_failed(project_id, import_id, "Failed to import gene set collection: #{e.message}", collection_id: collection_id)
  ensure
    if upload_file_path.present? && File.exist?(upload_file_path)
      File.delete(upload_file_path)
    end
  end

  private

  def broadcast_failed(project_id, import_id, message, collection_id: nil)
    return if project_id.blank?
    ActionCable.server.broadcast("project_#{project_id}", {
      event: 'gene_set_collection_import',
      status: 'failed',
      import_id: import_id,
      message: message.to_s,
      collection_id: collection_id
    })
  end

  def cleanup_failed_collection(project_id, collection_id)
    collection = GeneSetCollection.find_by(id: collection_id, project_id: project_id)
    return unless collection
    directory = manual_gene_set_collections_dir(Project.find_by(id: project_id))
    path = directory + "#{collection.file_key}.json"
    File.delete(path) if File.exist?(path)
    collection.destroy
  rescue StandardError
    nil
  end

  def write_local_gene_set_collection_payload(project, file_key, payload)
    directory = manual_gene_set_collections_dir(project)
    FileUtils.mkdir_p(directory) unless File.directory?(directory)
    File.write(local_gene_set_collection_file_path(project, file_key), JSON.pretty_generate(payload))
  end

  def manual_gene_set_collections_dir(project)
    return Pathname.new(ENV['USER_DATA_DIR'] || Rails.root.join('storage', 'user_data').to_s) + 'missing_project' unless project
    user_data_dir = ENV['USER_DATA_DIR'] || Rails.root.join('storage', 'user_data').to_s
    Pathname.new(user_data_dir) + project.user_id.to_s + project.key + 'gene_set_collections'
  end

  def local_gene_set_collection_file_path(project, file_key)
    normalized_key = file_key.to_s.strip
    raise ArgumentError, 'Invalid collection file key' unless normalized_key.match?(/\A[a-zA-Z0-9_-]+\z/)
    manual_gene_set_collections_dir(project) + "#{normalized_key}.json"
  end

  def parse_uploaded_gene_set_collection_items!(source_kind, file_content)
    case source_kind
    when 'gmt'
      parse_uploaded_gmt_items!(file_content)
    when 'json'
      parse_uploaded_json_items!(file_content)
    else
      raise ArgumentError, "Unsupported source kind: #{source_kind}"
    end
  end

  def parse_uploaded_gmt_items!(file_content)
    items = []
    lines = file_content.to_s.split(/\r?\n/)
    lines.each_with_index do |line, index|
      next if line.strip.blank?
      parts = line.split("\t")
      raise ArgumentError, "Invalid GMT format on line #{index + 1}: expected at least 3 tab-separated columns" if parts.length < 3

      raw_name = parts[0].to_s.strip
      gene_tokens = parts[2..].map { |value| value.to_s.strip }.reject(&:blank?).uniq
      raise ArgumentError, "Invalid GMT format on line #{index + 1}: missing gene set name" if raw_name.blank?
      raise ArgumentError, "Invalid GMT format on line #{index + 1}: no genes provided" if gene_tokens.empty?

      items << {
        identifier: raw_name,
        name: raw_name,
        genes: gene_tokens.map { |token| parse_uploaded_gene_token(token) }
      }
    end
    items
  end

  def parse_uploaded_json_items!(file_content)
    parsed = JSON.parse(file_content)
    raw_items = if parsed.is_a?(Hash)
                  Array(parsed['items'])
                elsif parsed.is_a?(Array)
                  parsed
                else
                  raise ArgumentError, 'Invalid JSON format. Expected an array of gene sets or an object with an items array.'
                end

    raw_items.each_with_index.map do |raw_item, index|
      raise ArgumentError, "Invalid JSON format for gene set at index #{index}" unless raw_item.is_a?(Hash)

      identifier = raw_item['identifier'].to_s.strip
      name = raw_item['name'].to_s.strip
      genes = raw_item['genes']
      raise ArgumentError, "Invalid genes value for gene set at index #{index}. Expected an array." unless genes.is_a?(Array)

      parsed_genes = genes.map.with_index do |entry, gene_index|
        parse_uploaded_gene_entry(entry, index, gene_index)
      end.compact
      raise ArgumentError, "Gene set at index #{index} has no valid genes" if parsed_genes.empty?

      { identifier: identifier, name: name, genes: parsed_genes }
    end
  end

  def parse_uploaded_gene_entry(entry, item_index, gene_index)
    return parse_uploaded_gene_token(entry) if entry.is_a?(String)
    raise ArgumentError, "Invalid gene entry at gene set #{item_index}, gene #{gene_index}" unless entry.is_a?(Hash)

    symbol = entry['symbol'].to_s.strip
    ensembl_id = entry['ensembl_id'].to_s.strip
    stable_id = entry['stable_id'].to_s.strip
    if symbol.blank? && ensembl_id.blank? && stable_id.blank?
      raise ArgumentError, "Invalid gene entry at gene set #{item_index}, gene #{gene_index}: empty symbol, ensembl_id and stable_id"
    end
    { symbol: symbol, ensembl_id: ensembl_id, stable_id: stable_id }
  end

  def parse_uploaded_gene_token(token)
    value = token.to_s.strip
    raise ArgumentError, 'Invalid gene token: empty value' if value.blank?

    if token_looks_like_accession?(value)
      { symbol: '', ensembl_id: value, stable_id: '' }
    else
      { symbol: value, ensembl_id: '', stable_id: '' }
    end
  end

  def token_looks_like_accession?(value)
    token = value.to_s.strip
    return false if token.blank?
    return true if token.match?(/\AENS[A-Z0-9]+\z/i)
    token.match?(/\A(?=.{6,}$)(?=(?:.*\d){3,})[A-Za-z0-9_.-]+\z/)
  end

  def normalize_uploaded_collection_items_for_storage(parsed_items, db_version:, collection_id:, timestamp:, resolve_gene_ids: true, resolve_symbol_gene_ids: true, organism_id: nil, dataset_stable_by_accession: {}, dataset_stable_by_symbol: {})
    normalized_identifiers = Set.new
    all_genes = parsed_items.flat_map { |item| Array(item[:genes]) }
    ensembl_lookup = {}
    symbol_lookup = {}
    if resolve_gene_ids
      ensembl_lookup, symbol_lookup = build_manual_gene_id_lookups(
        all_genes,
        db_version,
        resolve_symbol_lookup: resolve_symbol_gene_ids,
        organism_id: organism_id
      )
    else
      log_import(:info, 'lookup_skipped', genes: all_genes.length)
    end
    parsed_items.each_with_index.map do |item, index|
      token_seed = item[:identifier].presence || item[:name].presence || "item_#{index + 1}"
      item_identifier = normalize_uploaded_item_identifier(token_seed)
      suffix_index = 2
      while normalized_identifiers.include?(item_identifier)
        item_identifier = "#{normalize_uploaded_item_identifier(token_seed)}_#{suffix_index}"
        suffix_index += 1
      end
      normalized_identifiers.add(item_identifier)

      item_name = item[:name].presence || item[:identifier].presence || "Gene set #{index + 1}"
      genes_with_ids = resolve_manual_gene_ids_with_lookups(
        Array(item[:genes]),
        ensembl_lookup,
        symbol_lookup,
        dataset_stable_by_accession: dataset_stable_by_accession,
        dataset_stable_by_symbol: dataset_stable_by_symbol
      )
      {
        'id' => "#{collection_id}:#{item_identifier}",
        'identifier' => item_identifier,
        'name' => item_name,
        'genes' => genes_with_ids,
        'created_at' => timestamp,
        'updated_at' => timestamp
      }
    end
  end

  def normalize_uploaded_item_identifier(raw_value)
    normalized = raw_value.to_s.strip.gsub(/[^a-zA-Z0-9]+/, '_').gsub(/\A_+|_+\z/, '').downcase
    normalized.presence || "item_#{SecureRandom.hex(4)}"
  end

  def build_manual_gene_id_lookups(genes, db_version, resolve_symbol_lookup: true, organism_id: nil)
    return [{}, {}] unless genes.is_a?(Array)
    ensembl_keys = genes.map { |gene| gene[:ensembl_id].to_s.strip.downcase }.reject(&:blank?).uniq
    symbol_keys = genes.map { |gene| gene[:symbol].to_s.strip.downcase }.reject(&:blank?).uniq

    ensembl_lookup = {}
    symbol_lookup = {}
    lookup_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    RemoteGene.with_remote(db_version) do
      conn = RemoteGene.connection
      if organism_id.to_i > 0
        rows = conn.select_all("SELECT id, LOWER(COALESCE(ensembl_id, '')) AS ensembl_key, LOWER(COALESCE(name, '')) AS symbol_key FROM genes WHERE organism_id = #{organism_id.to_i}")
        rows.each do |row|
          gene_id = row['id'].to_i
          ensembl_key = row['ensembl_key'].to_s
          symbol_key = row['symbol_key'].to_s
          ensembl_lookup[ensembl_key] ||= gene_id if ensembl_key.present?
          symbol_lookup[symbol_key] ||= gene_id if symbol_key.present?
        end
        log_import(
          :info,
          'lookup_prefetched_organism',
          organism_id: organism_id.to_i,
          rows: rows.length,
          ensembl_keys: ensembl_lookup.length,
          symbol_keys: symbol_lookup.length
        )
        return [ensembl_lookup, symbol_lookup]
      end

      # Resolve ensembl-like IDs first, including raw symbol tokens.
      # Many datasets use non-ENS accessions in GMT files (for example AAEL...),
      # so looking up symbol tokens against ensembl_id first avoids expensive
      # symbol-name scans when tokens are actually IDs.
      candidate_ensembl_keys = (ensembl_keys + symbol_keys).uniq
      if candidate_ensembl_keys.any?
        candidate_ensembl_keys.each_slice(2000) do |slice|
          quoted = slice.map { |value| conn.quote(value) }.join(',')
          rows = conn.select_all("SELECT id, LOWER(COALESCE(ensembl_id, '')) AS key FROM genes WHERE LOWER(COALESCE(ensembl_id, '')) IN (#{quoted})")
          rows.each do |row|
            key = row['key'].to_s
            next if key.blank?
            ensembl_lookup[key] ||= row['id'].to_i
          end
        end
      end

      # Populate symbol lookup from keys already resolved through ensembl_id.
      symbol_keys.each do |key|
        next unless ensembl_lookup.key?(key)
        symbol_lookup[key] = ensembl_lookup[key]
      end

      remaining_symbol_keys = symbol_keys.reject { |key| symbol_lookup.key?(key) }
      if resolve_symbol_lookup && remaining_symbol_keys.any?
        remaining_symbol_keys.each_slice(2000) do |slice|
          quoted = slice.map { |value| conn.quote(value) }.join(',')
          rows = conn.select_all("SELECT id, LOWER(COALESCE(name, '')) AS key FROM genes WHERE LOWER(COALESCE(name, '')) IN (#{quoted})")
          rows.each do |row|
            key = row['key'].to_s
            next if key.blank?
            symbol_lookup[key] ||= row['id'].to_i
          end
        end
      end
    end
    log_import(
      :info,
      'lookup_completed',
      ensembl_keys: ensembl_keys.length,
      symbol_keys: symbol_keys.length,
      resolve_symbol_lookup: resolve_symbol_lookup,
      ensembl_resolved: ensembl_lookup.length,
      symbol_resolved: symbol_lookup.length,
      duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - lookup_started_at) * 1000).round
    )
    [ensembl_lookup, symbol_lookup]
  end

  def resolve_manual_gene_ids_with_lookups(genes, ensembl_lookup, symbol_lookup, dataset_stable_by_accession:, dataset_stable_by_symbol:)
    genes.map do |gene|
      symbol = gene[:symbol].to_s.strip
      ensembl_id = gene[:ensembl_id].to_s.strip
      stable_id = gene[:stable_id].to_s.strip
      gene_id = nil

      if ensembl_id.present?
        gene_id = ensembl_lookup[ensembl_id.downcase]
        if gene_id.nil? && symbol.blank?
          fallback_symbol_id = symbol_lookup[ensembl_id.downcase]
          if fallback_symbol_id
            gene_id = fallback_symbol_id
            symbol = ensembl_id
            ensembl_id = ''
          end
        end
      end

      if gene_id.nil? && symbol.present?
        gene_id = symbol_lookup[symbol.downcase]
        if gene_id.nil?
          fallback_ensembl_id = ensembl_lookup[symbol.downcase]
          if fallback_ensembl_id
            gene_id = fallback_ensembl_id
            ensembl_id = symbol
            symbol = ''
          end
        end
      end

      if stable_id.blank?
        ensembl_key = ensembl_id.downcase
        symbol_key = symbol.downcase
        stable_id = dataset_stable_by_accession[ensembl_key].to_s if ensembl_key.present?
        stable_id = dataset_stable_by_symbol[symbol_key].to_s if stable_id.blank? && symbol_key.present?
      end

      { symbol: symbol, ensembl_id: ensembl_id, stable_id: stable_id, gene_id: gene_id }
    end
  end

  def build_dataset_stable_lookup(project, loom_file)
    normalized_loom = loom_file.to_s.strip
    raise ArgumentError, 'Missing loom file' if normalized_loom.blank?

    user_data_dir = ENV['USER_DATA_DIR'] || Rails.root.join('storage', 'user_data').to_s
    project_dir = Pathname.new(user_data_dir) + project.user_id.to_s + project.key
    loom_path = project_dir + normalized_loom
    raise ArgumentError, 'Loom file not found' unless File.exist?(loom_path)

    stable_values = H5DataService.get_metadata_vector(loom_path.to_s, '/row_attrs/_StableID')
    accession_values = H5DataService.get_metadata_vector(loom_path.to_s, '/row_attrs/Accession')
    gene_values = H5DataService.get_metadata_vector(loom_path.to_s, '/row_attrs/Gene')
    size = [stable_values.length, accession_values.length, gene_values.length].min

    by_accession = {}
    by_symbol = {}
    size.times do |idx|
      stable_id = stable_values[idx].to_s.strip
      next if stable_id.blank?
      accession = accession_values[idx].to_s.strip.downcase
      symbol = gene_values[idx].to_s.strip.downcase
      by_accession[accession] ||= stable_id if accession.present?
      by_symbol[symbol] ||= stable_id if symbol.present?
    end

    log_import(:info, 'stable_lookup_built', rows: size, accession_keys: by_accession.length, symbol_keys: by_symbol.length)
    [by_accession, by_symbol]
  end

  def log_import(level, event, payload = {})
    logger = Rails.logger
    return unless logger
    context = payload.map { |key, value| "#{key}=#{value.inspect}" }.join(' ')
    message = "[GeneSetCollectionImportJob] event=#{event} #{context}".strip
    logger.public_send(level, message)
  rescue StandardError
    nil
  end
end
