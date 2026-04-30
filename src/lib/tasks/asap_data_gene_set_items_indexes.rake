# frozen_string_literal: true

module AsapDataBenchmarkGeneSetItems
  module_function

  def resolve_benchmark_project!
    pid = ENV["PROJECT_ID"].to_i
    return Project.find(pid) if pid.positive?

    key = ENV["PROJECT_KEY"].to_s.strip
    return Project.find_by!(key: key) if key.present?

    raise ArgumentError, "Set PROJECT_ID or PROJECT_KEY"
  end

  def resolve_benchmark_collection!(conn, project, label)
    label = label.to_s.strip
    raise ArgumentError, "GENE_SET_COLLECTION_LABEL is blank" if label.blank?

    visibility = [
      "(gs.project_id IS NULL AND gs.ref_id IS NOT NULL)",
      "gs.project_id = #{project.id.to_i}"
    ].join(" OR ")

    row = conn.select_one(<<~SQL)
      SELECT gs.id, gs.label
      FROM gene_sets gs
      WHERE gs.organism_id = #{project.organism_id.to_i}
        AND COALESCE(gs.obsolete, FALSE) = FALSE
        AND (#{visibility})
        AND LOWER(gs.label) = LOWER(#{conn.quote(label)})
      ORDER BY CASE WHEN gs.project_id IS NULL THEN 0 ELSE 1 END, gs.id
      LIMIT 1
    SQL

    unless row
      like = conn.quote("%#{label}%")
      row = conn.select_one(<<~SQL)
        SELECT gs.id, gs.label
        FROM gene_sets gs
        WHERE gs.organism_id = #{project.organism_id.to_i}
          AND COALESCE(gs.obsolete, FALSE) = FALSE
          AND (#{visibility})
          AND gs.label ILIKE #{like}
        ORDER BY CASE WHEN gs.project_id IS NULL THEN 0 ELSE 1 END, LENGTH(gs.label), gs.id
        LIMIT 1
      SQL
    end

    raise ArgumentError, "No gene_sets row matched label #{label.inspect} for organism_id=#{project.organism_id}" unless row

    { id: row["id"].to_i, label: row["label"].to_s }
  end

  def resolve_benchmark_loom_relative_path!(project_dir)
    default = project_dir + "parsing" + "output.loom"
    return "parsing/output.loom" if default.file?

    abs_paths = Dir.glob(File.join(project_dir.to_s, "**", "*.loom"))
    raise ArgumentError, "No .loom file found under #{project_dir}" if abs_paths.empty?

    abs = abs_paths.sort.first
    Pathname.new(abs).relative_path_from(project_dir).to_s
  end
end

namespace :asap_data do
  desc "Create btree + pg_trgm GIN indexes on gene_set_items (CONCURRENTLY) on each ASAP2_DATA_VERSIONS database"
  task ensure_gene_set_items_query_indexes: :environment do
    AsapData::GeneSetItemsQueryIndexes.apply_all_remote_shards!
  end

  desc "Benchmark gene_set_collection_items phases. ENV: PROJECT_ID or PROJECT_KEY; optional COLLECTION_ID, LOOM_FILE, GENE_SET_COLLECTION_LABEL (default GO biological processes), QUERY, ITERATIONS, LIMIT, USE_CACHE"
  task benchmark_gene_set_items: :environment do
    require "benchmark"
    require "set"

    project = AsapDataBenchmarkGeneSetItems.resolve_benchmark_project!
    collection_label = ENV.fetch("GENE_SET_COLLECTION_LABEL", "GO biological processes").strip
    collection_id = ENV["COLLECTION_ID"].to_i
    collection_name = nil
    loom_file = ENV["LOOM_FILE"].to_s.strip
    query = ENV["QUERY"].to_s.strip
    iterations = ENV.fetch("ITERATIONS", "5").to_i
    limit = ENV.fetch("LIMIT", "100").to_i
    use_cache = ENV.fetch("USE_CACHE", "true").to_s.strip.downcase == "true"

    raise ArgumentError, "ITERATIONS must be >= 1" if iterations <= 0
    raise ArgumentError, "LIMIT must be >= 1" if limit <= 0

    h_env = Basic.safe_parse_json(project.version&.env_json, {})
    db_version = h_env["asap_data_db_name"].to_s.strip
    raise ArgumentError, "Missing asap_data_db_name in project version env_json" if db_version.blank?

    user_data_dir = ENV["USER_DATA_DIR"] || Rails.root.join("storage", "user_data").to_s
    project_dir = Pathname.new(user_data_dir) + project.user_id.to_s + project.key

    RemoteGene.with_remote(db_version) do
      conn = Asap2RemoteRecord.connection
      if collection_id <= 0
        resolved = AsapDataBenchmarkGeneSetItems.resolve_benchmark_collection!(conn, project, collection_label)
        collection_id = resolved[:id]
        collection_name = resolved[:label]
      else
        row = conn.select_one(<<~SQL)
          SELECT id, label
          FROM gene_sets
          WHERE id = #{collection_id}
            AND organism_id = #{project.organism_id.to_i}
            AND COALESCE(obsolete, FALSE) = FALSE
        SQL
        raise ArgumentError, "COLLECTION_ID #{collection_id} not found for this organism" unless row

        collection_name = row["label"].to_s
      end
    end

    loom_file = AsapDataBenchmarkGeneSetItems.resolve_benchmark_loom_relative_path!(project_dir) if loom_file.blank?
    loom_path = project_dir + loom_file
    raise ArgumentError, "Loom file not found at #{loom_path}" unless File.exist?(loom_path)

    puts "Resolved benchmark inputs"
    puts "  project_id: #{project.id} key: #{project.key}"
    puts "  organism_id: #{project.organism_id}"
    puts "  collection_id: #{collection_id} label: #{collection_name || collection_label}"
    puts "  loom_file: #{loom_file}"
    puts

    phases = Hash.new { |h, k| h[k] = [] }
    row_count = 0
    total_count = 0

    lookup_key = "asap_data:benchmark_lookup:#{project.id}:#{loom_path}:#{File.mtime(loom_path).to_i}"

    iterations.times do |index|
      iter_label = index + 1
      puts "Iteration #{iter_label}/#{iterations}"

      dataset_stable_by_accession = {}
      dataset_stable_by_symbol = {}
      dataset_stable_ids = Set.new

      phases[:lookup_ms] << (Benchmark.realtime do
        build_lookup = proc do
          autocomplete_file = loom_path.dirname + "autocomplete_genes.json"
          parsed = AsapData::DatasetStableLookup.from_autocomplete_json_file(autocomplete_file.to_s)
          next parsed if parsed

          stable_values = H5DataService.get_metadata_vector(loom_path.to_s, "/row_attrs/_StableID")
          accession_values = H5DataService.get_metadata_vector(loom_path.to_s, "/row_attrs/Accession")
          gene_values = H5DataService.get_metadata_vector(loom_path.to_s, "/row_attrs/Gene")
          size = [stable_values.length, accession_values.length, gene_values.length].min
          by_accession = {}
          by_symbol = {}
          ids = Set.new
          size.times do |i|
            stable_id = stable_values[i].to_s.strip
            next if stable_id.blank?
            ids.add(stable_id)
            accession = accession_values[i].to_s.strip.downcase
            symbol = gene_values[i].to_s.strip.downcase
            by_accession[accession] ||= stable_id if accession.present?
            by_symbol[symbol] ||= stable_id if symbol.present?
          end
          { by_accession: by_accession, by_symbol: by_symbol, stable_ids: ids }
        end

        lookup = if use_cache
                   Rails.cache.fetch(lookup_key, expires_in: 6.hours) { build_lookup.call }
                 else
                   build_lookup.call
                 end

        dataset_stable_by_accession = lookup[:by_accession]
        dataset_stable_by_symbol = lookup[:by_symbol]
        dataset_stable_ids = lookup[:stable_ids]
      end * 1000.0)

      RemoteGene.with_remote(db_version) do
        conn = Asap2RemoteRecord.connection
        where_clause = "gene_set_id = #{collection_id}"
        if query.present?
          escaped_query = conn.quote("%#{query.downcase}%")
          where_clause += " AND LOWER(COALESCE(name, '')) LIKE #{escaped_query}"
        end

        phases[:count_ms] << (Benchmark.realtime do
          total_count = conn.select_value("SELECT COUNT(*) FROM gene_set_items WHERE #{where_clause}").to_i
        end * 1000.0)

        rows = []
        phases[:rows_ms] << (Benchmark.realtime do
          rows = conn.select_all(<<~SQL)
            SELECT id, identifier, name, content
            FROM gene_set_items
            WHERE #{where_clause}
            ORDER BY LOWER(COALESCE(name, ''))
            LIMIT #{limit}
          SQL
        end * 1000.0)
        row_count = rows.length

        all_gene_ids = []
        phases[:parse_gene_ids_ms] << (Benchmark.realtime do
          all_gene_ids = rows.flat_map do |row|
            row["content"].to_s.split(",").map(&:to_i).select { |v| v > 0 }
          end.uniq
        end * 1000.0)

        gene_lookup = {}
        phases[:gene_lookup_ms] << (Benchmark.realtime do
          if all_gene_ids.any?
            gene_rows = conn.select_all(<<~SQL)
              SELECT id, ensembl_id, name
              FROM genes
              WHERE id IN (#{all_gene_ids.join(",")})
            SQL
            gene_rows.each do |gene_row|
              gene_lookup[gene_row["id"].to_i] = {
                ensembl_id: gene_row["ensembl_id"].to_s,
                name: gene_row["name"].to_s
              }
            end
          end
        end * 1000.0)

        phases[:in_dataset_count_ms] << (Benchmark.realtime do
          rows.each do |row|
            row["content"].to_s.split(",").map(&:to_i).select { |v| v > 0 }.count do |gene_id|
              gene_info = gene_lookup[gene_id]
              next false unless gene_info
              accession_key = gene_info[:ensembl_id].to_s.strip.downcase
              symbol_key = gene_info[:name].to_s.strip.downcase
              (accession_key.present? && dataset_stable_by_accession.key?(accession_key)) ||
                (symbol_key.present? && dataset_stable_by_symbol.key?(symbol_key))
            end
          end
        end * 1000.0)
      end
    end

    puts
    puts "Benchmark results"
    puts "Project: #{project.id} (#{project.key})"
    puts "DB: #{db_version}"
    puts "Collection: #{collection_id} (#{collection_name || collection_label})"
    puts "Query: #{query.presence || '(none)'}"
    puts "Rows returned per iteration: #{row_count}"
    puts "Total matching items: #{total_count}"
    puts "Iterations: #{iterations}"
    puts "Cache enabled: #{use_cache}"
    puts

    phases.each do |name, values|
      avg = values.sum / values.length
      min = values.min
      max = values.max
      puts "#{name}: avg=#{format('%.1f', avg)}ms min=#{format('%.1f', min)}ms max=#{format('%.1f', max)}ms"
    end
  end
end
