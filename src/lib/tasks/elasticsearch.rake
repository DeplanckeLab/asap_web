# frozen_string_literal: true

require "csv"

module ElasticsearchProjectScroll
  module_function

  def parse_es_time(raw)
    return nil if raw.blank?

    Time.iso8601(raw.to_s)
  rescue ArgumentError
    nil
  end

  def scroll_project_sources(client, index, source_fields)
    es_by_id = {}
    body = {
      query: { match_all: {} },
      size: 1000,
      sort: [{ _doc: "asc" }],
      _source: source_fields
    }
    response = client.search(index: index, scroll: "5m", body: body)
    scroll_id = response["_scroll_id"]

    begin
      loop do
        hits = response["hits"]["hits"]
        break if hits.blank?

        hits.each do |hit|
          id = hit["_id"].to_i
          next if id <= 0

          es_by_id[id] = hit["_source"] || {}
        end
        break if scroll_id.blank?

        response = client.scroll(scroll: "5m", body: { scroll_id: scroll_id })
        scroll_id = response["_scroll_id"].presence || scroll_id
      end
    ensure
      client.clear_scroll(body: { scroll_id: [scroll_id] }) if scroll_id.present?
    end

    es_by_id
  end

  def scroll_project_ids(client, index)
    ids = []
    body = {
      query: { match_all: {} },
      size: 1000,
      sort: [{ _doc: "asc" }],
      _source: false
    }
    response = client.search(index: index, scroll: "5m", body: body)
    scroll_id = response["_scroll_id"]

    begin
      loop do
        hits = response["hits"]["hits"]
        break if hits.blank?

        hits.each do |hit|
          id = hit["_id"].to_i
          ids << id if id.positive?
        end
        break if scroll_id.blank?

        response = client.scroll(scroll: "5m", body: { scroll_id: scroll_id })
        scroll_id = response["_scroll_id"].presence || scroll_id
      end
    ensure
      client.clear_scroll(body: { scroll_id: [scroll_id] }) if scroll_id.present?
    end

    ids
  end
end

namespace :elasticsearch do
  desc <<~DESC.squish
    Export every document in the Elasticsearch projects index to CSV.
    Default path is ../private/elasticsearch_projects_full.csv relative to Rails.root
    (same layout as the earlier since-2026-04-20 export: repo private/ next to src/).
    In Docker (Rails.root is /app) set ELASTICSEARCH_PROJECTS_CSV=/app/tmp/elasticsearch_projects_full.csv
    then copy from host src/tmp/ into private/. Override with ELASTICSEARCH_PROJECTS_CSV for any path.
  DESC
  task export_projects_csv: :environment do
    client = Elasticsearch::Model.client
    index = Project.__elasticsearch__.index_name
    out_path = ENV.fetch("ELASTICSEARCH_PROJECTS_CSV") do
      File.expand_path("../private/elasticsearch_projects_full.csv", Rails.root)
    end

    unless Project.__elasticsearch__.index_exists?
      abort "Elasticsearch index does not exist: #{index}"
    end

    FileUtils.mkdir_p(File.dirname(out_path))

    headers = %w[
      es_id name key description technology project_type_name tissue organism_name status_name
      public being_deleted created_at updated_at nber_cols nber_rows nber_views nber_cloned
      disk_size user_id owner_email shared_user_ids
    ]

    cell = lambda do |v|
      return "" if v.nil?
      return v.to_json if v.is_a?(Array)

      v
    end

    body = {
      query: { match_all: {} },
      size: 1000,
      sort: [{ _doc: "asc" }]
    }

    response = client.search(index: index, scroll: "5m", body: body)
    scroll_id = response["_scroll_id"]
    count = 0

    CSV.open(out_path, "w", write_headers: true, headers: headers) do |csv|
      loop do
        hits = response["hits"]["hits"]
        break if hits.blank?

        hits.each do |hit|
          src = hit["_source"] || {}
          csv << [
            hit["_id"],
            cell.call(src["name"]),
            cell.call(src["key"]),
            cell.call(src["description"]),
            cell.call(src["technology"]),
            cell.call(src["project_type_name"]),
            cell.call(src["tissue"]),
            cell.call(src["organism_name"]),
            cell.call(src["status_name"]),
            cell.call(src["public"]),
            cell.call(src["being_deleted"]),
            cell.call(src["created_at"]),
            cell.call(src["updated_at"]),
            cell.call(src["nber_cols"]),
            cell.call(src["nber_rows"]),
            cell.call(src["nber_views"]),
            cell.call(src["nber_cloned"]),
            cell.call(src["disk_size"]),
            cell.call(src["user_id"]),
            cell.call(src["owner_email"]),
            cell.call(src["shared_user_ids"])
          ]
          count += 1
        end

        break if scroll_id.blank?

        response = client.scroll(scroll: "5m", body: { scroll_id: scroll_id })
        scroll_id = response["_scroll_id"].presence || scroll_id
      end
    end

    client.clear_scroll(body: { scroll_id: [scroll_id] }) if scroll_id.present?
    puts "[elasticsearch:export_projects_csv] wrote #{count} rows to #{out_path}"
  end

  desc <<~DESC.squish
    Compare Postgres to Elasticsearch only for projects that have an ES document (intersection).
    Postgres rows with no ES hit are ignored for drift: project presence uses disk and S3, not the index.
    Elasticsearch is ground truth for indexed fields only (here being_deleted and updated_at).
    archive_status_id is not indexed and is not compared; archive state follows disk and S3 plus DB workflows.
    Read-only: no writes to Postgres or Elasticsearch. DRY_RUN defaults to 1; set DRY_RUN=0 only to acknowledge a future write step (none today).
    Counts: ES doc but no DB row; being_deleted mismatch; updated_at mismatch (> 1s); postgres-vs-es newer breakdown.
    Prints the first UPDATED_AT_SAMPLE_N (default 5) updated_at mismatches with timestamps and delta_seconds.
    Set VERBOSE=1 for sample ids (first 30 per bucket).
  DESC
  task compare_projects_database: :environment do
    dry_run = ENV["DRY_RUN"] != "0"
    verbose = ENV["VERBOSE"].to_s
    sample_n = ENV.fetch("UPDATED_AT_SAMPLE_N", "5").to_i
    sample_n = sample_n.clamp(0, 30)
    client = Elasticsearch::Model.client
    index = Project.__elasticsearch__.index_name

    unless Project.__elasticsearch__.index_exists?
      abort "Elasticsearch index does not exist: #{index}"
    end

    es_by_id = ElasticsearchProjectScroll.scroll_project_sources(client, index, %w[being_deleted updated_at])

    es_ids = es_by_id.keys.to_set
    db_ids = Project.pluck(:id).to_set
    overlap_ids = es_ids & db_ids
    rows = Project.where(id: overlap_ids.to_a).pluck(:id, :being_deleted, :updated_at)
    db_by_id = rows.to_h { |(id, bd, ua)| [id, { being_deleted: bd, updated_at: ua }] }

    in_es_not_in_db = es_ids - db_ids

    being_deleted_diff = []
    updated_at_diff = []
    updated_at_db_newer = 0
    updated_at_es_newer = 0

    es_bool = lambda do |v|
      v == true || v == "true"
    end

    overlap_ids.each do |id|
      db = db_by_id[id]
      src = es_by_id[id]

      if !!db[:being_deleted] != es_bool.call(src["being_deleted"])
        being_deleted_diff << id
      end

      es_t = ElasticsearchProjectScroll.parse_es_time(src["updated_at"])
      db_t = db[:updated_at]
      if es_t.nil? || db_t.nil?
        updated_at_diff << id if es_t != db_t
      elsif (db_t.utc - es_t.utc).abs > 1
        updated_at_diff << id
        if db_t.utc > es_t.utc
          updated_at_db_newer += 1
        else
          updated_at_es_newer += 1
        end
      end
    end

    puts "[elasticsearch:compare_projects_database] index=#{index} dry_run=#{dry_run} (read-only)"
    puts "  elasticsearch_documents: #{es_ids.size}"
    puts "  postgres_project_rows: #{db_ids.size}"
    puts "  compared_intersection_db_and_es: #{overlap_ids.size}"
    puts "  in_elasticsearch_not_in_database: #{in_es_not_in_db.size}"
    puts "  being_deleted_differs_from_elasticsearch: #{being_deleted_diff.size}"
    puts "  updated_at_differs_from_elasticsearch_gt_1s: #{updated_at_diff.size}"
    puts "  updated_at_postgres_newer_than_elasticsearch_gt_1s: #{updated_at_db_newer}"
    puts "  updated_at_elasticsearch_newer_than_postgres_gt_1s: #{updated_at_es_newer}"

    if sample_n.positive? && updated_at_diff.any?
      puts "  updated_at_mismatch_samples (postgres vs elasticsearch, delta_seconds = postgres minus elasticsearch):"
      updated_at_diff.sort.first(sample_n).each do |sid|
        db = db_by_id[sid]
        es_t = ElasticsearchProjectScroll.parse_es_time(es_by_id[sid]["updated_at"])
        db_t = db[:updated_at]
        delta =
          if db_t && es_t
            (db_t.utc - es_t.utc).to_f
          else
            nil
          end
        puts "    project_id=#{sid} postgres_updated_at=#{db_t&.utc&.iso8601(3)} elasticsearch_updated_at=#{es_t&.utc&.iso8601(3)} delta_seconds=#{delta.inspect}"
      end
    end

    if verbose == "1"
      sample = ->(arr) { arr.first(30).join(", ") }
      puts "  sample_in_es_not_in_db: #{sample.call(in_es_not_in_db.to_a.sort)}"
      puts "  sample_being_deleted_diff: #{sample.call(being_deleted_diff.sort)}"
      puts "  sample_updated_at_diff: #{sample.call(updated_at_diff.sort)}"
    end
  end

  desc <<~DESC.squish
    Copy Elasticsearch _source.updated_at onto projects.updated_at using update_all (no callbacks, no implicit touch).
    Only projects that exist in Postgres and have an ES document are considered.
    DRY_RUN defaults to 1. MODE=drift (default): only rows where Postgres updated_at is more than 1 second newer than ES
    (typical after a bulk save that bumped timestamps). MODE=all: set from ES whenever ES has a parseable updated_at.
    PROJECT_IDS=id1,id2 limits which ES ids are processed.
  DESC
  task restore_project_updated_at_from_index: :environment do
    dry_run = ENV["DRY_RUN"] != "0"
    mode = ENV.fetch("MODE", "drift").strip.downcase
    abort "MODE must be drift or all" unless %w[drift all].include?(mode)

    id_list = ENV["PROJECT_IDS"].to_s.split(",").map(&:strip).map(&:to_i).reject(&:zero?)
    id_filter_set = id_list.any? ? id_list.to_set : nil

    client = Elasticsearch::Model.client
    index = Project.__elasticsearch__.index_name

    unless Project.__elasticsearch__.index_exists?
      abort "Elasticsearch index does not exist: #{index}"
    end

    es_by_id = ElasticsearchProjectScroll.scroll_project_sources(client, index, %w[updated_at])
    es_by_id.select! { |k, _| id_filter_set.include?(k) } if id_filter_set

    db_ids = Project.pluck(:id).to_set
    overlap = es_by_id.keys.to_set & db_ids

    candidates = []
    overlap.each do |id|
      src = es_by_id[id]
      es_t = ElasticsearchProjectScroll.parse_es_time(src["updated_at"])
      next unless es_t

      db_t = Project.where(id: id).pick(:updated_at)
      next unless db_t

      if mode == "drift"
        next unless db_t.utc > es_t.utc + 1
      end

      candidates << [id, es_t, db_t]
    end

    puts "[elasticsearch:restore_project_updated_at_from_index] index=#{index} dry_run=#{dry_run} mode=#{mode} " \
         "candidates=#{candidates.size}"

    if dry_run
      puts "[elasticsearch:restore_project_updated_at_from_index] dry_run: no rows written; run with DRY_RUN=0 to apply"
    else
      candidates.each do |id, es_t, _db_t|
        Project.where(id: id).update_all(updated_at: es_t)
      end
      puts "[elasticsearch:restore_project_updated_at_from_index] applied updated_at for #{candidates.size} rows"
    end
  end

  desc <<~DESC.squish
    Read-only audit in two parts: (1) Postgres projects with archive_status_id IS DISTINCT FROM 3 (not archived-on-S3 in DB)
    checked against USER_DATA_DIR using Project#filesystem_project_data_present? (directory with more than ~10KB),
    optional S3 archive bucket head_object on project.key (same bucket as archive.rake archive_s3_bucket_config).
    INCLUDE_S3=0 skips S3 (then deleted_like_no_disk_no_s3 is never true). DRY_RUN is ignored (no writes).
    MISSING_DISK_SAMPLE_N (default 15) lists sample not-archived ids without usable disk data.
    (2) Every postgres row missing from the Elasticsearch index (any archive_status) is printed with disk and S3 flags
    so you can see deleted_like_no_disk_no_s3 when INCLUDE_S3=1.
  DESC
  task audit_unarchived_storage_and_es: :environment do
    include_s3 = ENV["INCLUDE_S3"] != "0"
    sample_n = ENV.fetch("MISSING_DISK_SAMPLE_N", "15").to_i.clamp(0, 200)

    client = Elasticsearch::Model.client
    index = Project.__elasticsearch__.index_name

    unless Project.__elasticsearch__.index_exists?
      abort "Elasticsearch index does not exist: #{index}"
    end

    es_ids = ElasticsearchProjectScroll.scroll_project_ids(client, index).to_set

    s3_client = nil
    s3_bucket = nil
    if include_s3
      s3b = archive_s3_bucket_config
      s3_bucket = s3b[:key]
      h = Basic.get_s3_settings
      s3_client = Basic.connect_s3(s3b, h)
    end

    s3_key_exists = lambda do |project|
      return :skipped unless include_s3 && s3_client && s3_bucket
      return :no_key unless project.key.present?

      s3_client.head_object(bucket: s3_bucket, key: project.key)
      true
    rescue Aws::S3::Errors::NotFound, Aws::S3::Errors::NoSuchKey
      false
    rescue StandardError => e
      "error:#{e.class}"
    end

    scope = Project.where("archive_status_id IS DISTINCT FROM ?", 3)
    total = scope.count
    disk_ok = 0
    disk_missing = 0
    disk_skip = 0
    s3_true = 0
    s3_false = 0
    s3_err = 0
    s3_skip = 0
    missing_disk_ids = []

    scope.find_each do |project|
      unless project.user_id.present? && project.key.present?
        disk_skip += 1
        next
      end

      dir = project.storage_dir
      dir_exists = File.directory?(dir.to_s)
      populated = project.filesystem_project_data_present?

      if populated
        disk_ok += 1
      else
        disk_missing += 1
        missing_disk_ids << project.id
      end

      next unless include_s3

      sx = s3_key_exists.call(project)
      case sx
      when true
        s3_true += 1
      when false
        s3_false += 1
      when :skipped, :no_key
        s3_skip += 1
      else
        s3_err += 1
      end
    end

    puts "[elasticsearch:audit_unarchived_storage_and_es] part1_not_archived_db_scope=archive_status_id IS DISTINCT FROM 3 count=#{total}"
    puts "  filesystem_project_data_present_true: #{disk_ok}"
    puts "  filesystem_project_data_present_false: #{disk_missing}"
    puts "  skipped_missing_user_id_or_key: #{disk_skip}"
    if include_s3
      puts "  s3_head_object_present: #{s3_true}"
      puts "  s3_head_object_absent: #{s3_false}"
      puts "  s3_head_skipped_or_no_key: #{s3_skip}"
      puts "  s3_head_error: #{s3_err}"
    else
      puts "  s3: skipped (INCLUDE_S3=0)"
    end

    if sample_n.positive? && missing_disk_ids.any?
      puts "  sample_not_archived_without_usable_disk_data (first #{sample_n}): #{missing_disk_ids.first(sample_n).join(', ')}"
    end

    db_ids = Project.pluck(:id).to_set
    not_in_es = db_ids - es_ids
    puts "part2_postgres_rows_not_in_elasticsearch_index: #{not_in_es.size}"

    not_in_es.each do |pid|
      p = Project.find_by(id: pid)
      unless p
        puts "    id=#{pid} row_missing"
        next
      end

      unless p.user_id.present? && p.key.present?
        puts "    id=#{p.id} key=#{p.key.inspect} user_id=#{p.user_id.inspect} in_elasticsearch=false skip_disk_s3"
        next
      end

      populated = p.filesystem_project_data_present?
      dir_exists = File.directory?(p.storage_dir.to_s)
      sx = include_s3 ? s3_key_exists.call(p) : :skipped
      s3_label =
        case sx
        when true then "s3=yes"
        when false then "s3=no"
        when :skipped then "s3=skipped"
        when :no_key then "s3=no_key"
        else "s3=#{sx}"
        end

      deleted_like = include_s3 && !populated && sx == false
      puts "    id=#{p.id} key=#{p.key} archive_status_id=#{p.archive_status_id.inspect} being_deleted=#{p.being_deleted} " \
           "in_elasticsearch=false disk_populated=#{populated} disk_dir_exists=#{dir_exists} #{s3_label} " \
           "deleted_like_no_disk_no_s3=#{deleted_like}"
    end
  end

  desc "Index all projects in Elasticsearch"
  task index_projects: :environment do
    puts "Indexing projects in Elasticsearch..."
    
    # Create index if it doesn't exist
    unless Project.__elasticsearch__.index_exists?
      Project.__elasticsearch__.create_index!(force: true)
      puts "Created Elasticsearch index for projects"
    end
    
    # Index all projects
    Project.find_each do |project|
      begin
        # Skip indexing if project has missing required fields
        next unless project.respond_to?(:name) && project.respond_to?(:key)
        
        project.__elasticsearch__.index_document
        print "."
      rescue => e
        puts "\nError indexing project #{project.id}: #{e.message}"
        next
      end
    end
    
    puts "\nIndexing complete!"
    puts "Total projects indexed: #{Project.count}"
  end
  
  desc "Reindex all projects in Elasticsearch"
  task reindex_projects: :environment do
    puts "Reindexing projects in Elasticsearch..."
    
    # Delete existing index
    if Project.__elasticsearch__.index_exists?
      Project.__elasticsearch__.delete_index!
      puts "Deleted existing index"
    end
    
    # Create new index
    Project.__elasticsearch__.create_index!(force: true)
    puts "Created new index"
    
    # Index all projects
    Project.find_each do |project|
      begin
        # Skip indexing if project has missing required fields
        next unless project.respond_to?(:name) && project.respond_to?(:key)
        
        project.__elasticsearch__.index_document
        print "."
      rescue => e
        puts "\nError indexing project #{project.id}: #{e.message}"
        next
      end
    end
    
    puts "\nReindexing complete!"
    puts "Total projects indexed: #{Project.count}"
  end
  
  desc "Check Elasticsearch status"
  task status: :environment do
    begin
      client = Elasticsearch::Model.client
      info = client.info
      puts "Elasticsearch is running:"
      puts "  Version: #{info['version']['number']}"
      puts "  Cluster: #{info['cluster_name']}"
      puts "  Node: #{info['name']}"
      
      if Project.__elasticsearch__.index_exists?
        count = Project.__elasticsearch__.search(size: 0).response['hits']['total']['value']
        puts "  Projects indexed: #{count}"
      else
        puts "  Projects index: Not found"
      end
    rescue => e
      puts "Error connecting to Elasticsearch: #{e.message}"
    end
  end
end
