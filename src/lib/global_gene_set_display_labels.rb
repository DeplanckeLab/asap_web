module GlobalGeneSetDisplayLabels
  module_function

  def format_item_label(identifier, name)
    id = identifier.to_s.strip
    nm = name.to_s.strip
    if id.present? && nm.present?
      return nm if id == nm
      return "#{id} #{nm}"
    end
    return id if id.present?
    return nm if nm.present?
    nil
  end

  def collection_label_from_row(row)
    db_label = row['database_name'].to_s.strip
    gs_label = row['label'].to_s.strip
    if db_label.present? && gs_label.present?
      return db_label if db_label.casecmp?(gs_label)
      return "#{db_label} - #{gs_label}"
    end
    db_label.presence || gs_label.presence || "Collection #{row['id']}"
  end

  def module_score_gene_set_badge_labels(collection_label, item_label)
    item = item_label.to_s.strip
    collection = collection_label.to_s.strip
    display = item.presence || collection
    tooltip = if collection.present? && item.present? && collection != item
                "#{collection} · #{item}"
              else
                display
              end
    { display: display, tooltip: tooltip }
  end

  def fetch(project, collection_ids: [], item_ids: [])
    collection_ids = Array(collection_ids).map(&:to_i).uniq.reject(&:zero?)
    item_ids = Array(item_ids).map(&:to_i).uniq.reject(&:zero?)
    return { collections: {}, items: {} } if collection_ids.empty? && item_ids.empty?

    h_env = Basic.safe_parse_json(project.version.env_json, {})
    db_name = Basic.asap_data_db_name_from_env!(h_env)
    collections = {}
    items = {}

    RemoteGene.with_remote(db_name) do
      conn = RemoteGene.connection
      if collection_ids.any?
        rows = conn.select_all(<<~SQL)
          SELECT gs.id, gs.label, ds.label AS database_name
          FROM gene_sets gs
          LEFT JOIN db_sets ds ON ds.id = gs.ref_id
          WHERE gs.id IN (#{collection_ids.join(',')})
            AND gs.organism_id = #{project.organism_id.to_i}
        SQL
        rows.each do |row|
          collections[row['id'].to_i] = collection_label_from_row(row)
        end
      end

      if item_ids.any?
        rows = conn.select_all(<<~SQL)
          SELECT id, identifier, name
          FROM gene_set_items
          WHERE id IN (#{item_ids.join(',')})
        SQL
        rows.each do |row|
          label = format_item_label(row['identifier'], row['name'])
          items[row['id'].to_i] = label.presence || "Item #{row['id']}"
        end
      end
    end

    { collections: collections, items: items }
  rescue StandardError => e
    Rails.logger.error("[GlobalGeneSetDisplayLabels] #{e.class}: #{e.message}")
    { collections: {}, items: {} }
  end
end
