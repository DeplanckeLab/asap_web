# frozen_string_literal: true

namespace :projects do
  desc <<~DESC.squish
    Upsert projects from the Elasticsearch `projects` index for documents with
    created_at or updated_at on or after SINCE (default 2026-04-20, UTC).
    Updates only ES-backed columns on conflict so fu_id, parsing_attrs_json, version_id, etc. are preserved.
    Set DRY_RUN=1 to print counts and sample without writing.
    Set MERGE_FU_ID=0 to skip setting fu_id from fus when it is NULL.
  DESC
  task recover_from_elasticsearch: :environment do
    since = ENV.fetch("SINCE", "2026-04-20").to_s.strip
    since_ts = "#{since}T00:00:00.000Z"
    dry_run = ENV["DRY_RUN"] == "1"
    merge_fu = ENV["MERGE_FU_ID"] != "0"

    client = Elasticsearch::Model.client
    body = {
      query: {
        bool: {
          should: [
            { range: { created_at: { gte: since_ts } } },
            { range: { updated_at: { gte: since_ts } } }
          ],
          minimum_should_match: 1
        }
      },
      size: 10_000,
      sort: [{ updated_at: "desc" }],
      _source: true
    }
    res = client.search(index: Project.__elasticsearch__.index_name, body: body)
    hits = res["hits"]["hits"] || []
    total = res["hits"]["total"]
    n = total.is_a?(Hash) ? total["value"] : total
    puts "[recover_from_elasticsearch] since=#{since_ts} hits=#{hits.size} total=#{n} dry_run=#{dry_run}"

    conn = ActiveRecord::Base.connection
    q = ->(v) { conn.quote(v) }

    organism_cache = {}
    status_cache = {}
    project_type_cache = {}

    hits.each do |hit|
      id = hit["_id"].to_i
      next if id <= 0

      src = hit["_source"] || {}
      key = src["key"].to_s
      next if key.blank?

      name = src["name"].to_s
      description = src["description"].to_s
      user_id = src["user_id"].presence&.to_i

      org_name = src["organism_name"].to_s.strip
      organism_id = if org_name.blank?
                      1
                    else
                      organism_cache[org_name] ||= Organism.where("name ILIKE ?", org_name).pick(:id) || 1
                    end

      pt_name = src["project_type_name"].to_s.strip
      project_type_id = if pt_name.blank?
                           nil
                         else
                           project_type_cache[pt_name] ||= ProjectType.where(name: pt_name).pick(:id)
                         end

      st_name = src["status_name"].to_s.strip
      status_id = if st_name.blank?
                     1
                   else
                     status_cache[st_name] ||= Status.where(name: st_name).pick(:id) || 1
                   end

      public_flag = ActiveModel::Type::Boolean.new.cast(src["public"])
      being_deleted_flag = ActiveModel::Type::Boolean.new.cast(src["being_deleted"])

      nber_rows = src["nber_rows"].presence&.to_i
      nber_cols = src["nber_cols"].presence&.to_i
      nber_views = src["nber_views"].presence&.to_i
      nber_cloned = src["nber_cloned"].presence&.to_i
      disk_size = src["disk_size"].presence&.to_i

      tech = src["technology"]
      technology = tech.is_a?(Array) ? tech.compact.join(", ") : tech.to_s.presence
      tis = src["tissue"]
      tissue = tis.is_a?(Array) ? tis.compact.join(", ") : tis.to_s.presence

      created_at = src["created_at"].presence
      updated_at = src["updated_at"].presence
      next if created_at.blank? || updated_at.blank?

      vals = [
        id,
        q.call(key),
        q.call(name),
        q.call(description),
        user_id.nil? ? "NULL" : user_id,
        organism_id,
        project_type_id.nil? ? "NULL" : project_type_id,
        status_id,
        public_flag ? "TRUE" : "FALSE",
        being_deleted_flag ? "TRUE" : "FALSE",
        nber_rows.nil? ? "NULL" : nber_rows,
        nber_cols.nil? ? "NULL" : nber_cols,
        nber_views.nil? ? "NULL" : nber_views,
        nber_cloned.nil? ? "NULL" : nber_cloned,
        disk_size.nil? ? "NULL" : disk_size,
        q.call(created_at),
        q.call(updated_at),
        technology.nil? ? "NULL" : q.call(technology),
        tissue.nil? ? "NULL" : q.call(tissue)
      ].join(", ")

      sql = <<~SQL.squish
        INSERT INTO projects (
          id, key, name, description, user_id, organism_id, project_type_id, status_id,
          public, being_deleted, nber_rows, nber_cols, nber_views, nber_cloned, disk_size,
          created_at, updated_at, technology, tissue
        ) VALUES (#{vals})
        ON CONFLICT (id) DO UPDATE SET
          key = EXCLUDED.key,
          name = EXCLUDED.name,
          description = EXCLUDED.description,
          user_id = EXCLUDED.user_id,
          organism_id = EXCLUDED.organism_id,
          project_type_id = EXCLUDED.project_type_id,
          status_id = EXCLUDED.status_id,
          public = EXCLUDED.public,
          being_deleted = EXCLUDED.being_deleted,
          nber_rows = EXCLUDED.nber_rows,
          nber_cols = EXCLUDED.nber_cols,
          nber_views = EXCLUDED.nber_views,
          nber_cloned = EXCLUDED.nber_cloned,
          disk_size = EXCLUDED.disk_size,
          created_at = EXCLUDED.created_at,
          updated_at = EXCLUDED.updated_at,
          technology = EXCLUDED.technology,
          tissue = EXCLUDED.tissue
      SQL

      if dry_run
        puts "  [dry-run] id=#{id} key=#{key}"
      else
        conn.execute(sql)
        puts "  upsert id=#{id} key=#{key}"
      end
    end

    unless dry_run
      if merge_fu
        res = conn.execute(<<~SQL.squish)
          UPDATE projects p
          SET fu_id = s.fu_id
          FROM (
            SELECT DISTINCT ON (project_id) project_id, id AS fu_id
            FROM fus
            ORDER BY project_id, id DESC
          ) s
          WHERE p.id = s.project_id AND p.fu_id IS NULL
        SQL
        n = res.respond_to?(:cmd_tuples) ? res.cmd_tuples : 0
        puts "[recover_from_elasticsearch] merged fu_id for #{n} rows where fu_id was NULL"
      end

      max_id = conn.select_value("SELECT MAX(id) FROM projects").to_i
      seq = conn.select_value("SELECT pg_get_serial_sequence('projects', 'id')")
      if seq.present?
        conn.execute("SELECT setval(#{q.call(seq)}, #{max_id.to_i}, true)")
        puts "[recover_from_elasticsearch] setval #{seq} to #{max_id}"
      end
    end

    puts "[recover_from_elasticsearch] done"
  end

  desc <<~DESC.squish
    Recompute projects.nber_runs_json and each project_steps.nber_runs_json from runs
    (used by the header run status summary and GET /projects/:id/run_counts).
    Pass PROJECT_IDS=id1,id2 to limit scope; otherwise all projects that have at least one run.
    DRY_RUN=1 lists projects only.
  DESC
  task rebuild_run_status_summaries: :environment do
    dry_run = ENV["DRY_RUN"] == "1"
    ids = ENV["PROJECT_IDS"].to_s.split(",").map(&:strip).reject(&:empty?).map(&:to_i).reject(&:zero?)

    scope =
      if ids.any?
        Project.where(id: ids)
      else
        Project.where(id: Run.distinct.select(:project_id))
      end

    total = scope.count
    puts "[rebuild_run_status_summaries] projects=#{total} dry_run=#{dry_run}"

    done = 0
    scope.find_each do |project|
      step_ids = Run.where(project_id: project.id).distinct.pluck(:step_id)
      next if step_ids.empty?

      if dry_run
        puts "  [dry-run] project_id=#{project.id} key=#{project.key} steps=#{step_ids.size}"
      else
        step_ids.each { |sid| Basic.upd_project_step(project, sid) }
      end
      done += 1
      puts "  rebuilt #{done}/#{total} id=#{project.id}" if (done % 200).zero? && !dry_run
    end

    puts "[rebuild_run_status_summaries] finished #{done} projects"
  end

  desc <<~DESC.squish
    Set version_id from the earliest run's step (Run.order(:id).first, then steps.version_id).
    Uses update_column(:version_id, ...) so updated_at is not touched.
    Default scope: projects with version_id IS NULL only (same as before).
    Set REALIGN_MISMATCH=1 to also consider projects whose version_id already differs from that inferred
    value (e.g. after correcting steps.version_id for runs that were inferred earlier).
    Legacy ASAP (projects.version_id 1, 2, or 3) is excluded: not scanned in REALIGN mode, and each row
    is skipped if version_id is set and below 4 (e.g. PROJECT_IDS including a legacy id). Inferred version_id
    below 4 is never applied.
    Skips projects with no runs, missing steps, steps with NULL version_id, or when project.version_id
    already equals the inferred value.
    DRY_RUN defaults to on; set DRY_RUN=0 to apply. PROJECT_IDS=id1,id2 limits which projects are scanned.
    Set VERBOSE=1 to print each assignment (dry-run or apply).
  DESC
  task infer_version_id_from_runs: :environment do
    dry_run = ENV["DRY_RUN"] != "0"
    verbose = ENV["VERBOSE"] == "1"
    realign_mismatch = ENV["REALIGN_MISMATCH"] == "1"
    id_list = ENV["PROJECT_IDS"].to_s.split(",").map(&:strip).map(&:to_i).reject(&:zero?)

    scope =
      if realign_mismatch
        # Do not touch asap-old style projects (version_id 1, 2, 3).
        s = Project.where("version_id IS NULL OR version_id >= 4")
        s = s.where(id: id_list) if id_list.any?
        s
      else
        s = Project.where(version_id: nil)
        s = s.where(id: id_list) if id_list.any?
        s
      end

    total_candidates = scope.count
    counts = Hash.new(0)

    scope.find_each do |project|
      if project.version_id.present? && project.version_id < 4
        counts[:skip_project_version_below_4] += 1
        next
      end

      run = Run.where(project_id: project.id).order(:id).first
      unless run
        counts[:skip_no_runs] += 1
        next
      end

      step = Step.find_by(id: run.step_id)
      unless step
        counts[:skip_no_step] += 1
        next
      end

      vid = step.version_id
      if vid.blank?
        counts[:skip_step_version_id_blank] += 1
        next
      end

      unless Version.exists?(id: vid)
        counts[:skip_version_row_missing] += 1
        next
      end

      if vid < 4
        counts[:skip_inferred_version_below_4] += 1
        next
      end

      if project.version_id == vid
        counts[:skip_already_match] += 1
        next
      end

      if verbose
        puts "  project_id=#{project.id} key=#{project.key} run_id=#{run.id} step_id=#{step.id} " \
             "current_version_id=#{project.version_id.inspect} inferred_version_id=#{vid}"
      end

      if dry_run
        counts[:would_update] += 1
      else
        project.update_column(:version_id, vid)
        counts[:updated] += 1
      end
    end

    puts "[projects:infer_version_id_from_runs] dry_run=#{dry_run} realign_mismatch=#{realign_mismatch} " \
         "candidates=#{total_candidates}"
    puts "  #{counts.map { |k, v| "#{k}=#{v}" }.join(' ')}"
    puts "[projects:infer_version_id_from_runs] done"
  end

  desc <<~DESC.squish
    Restore projects.version_id from a tab-separated file with header row:
    id, key, version_id (same shape as extract_project_version_ids_from_dump.py output with --delimiter tab).
    Uses update_column(:version_id, ...) so updated_at is not modified.
    Each line must match the database: Project#key must equal the file key for that id, or the task aborts.
    Blank version_id becomes NULL. Referenced Version rows must exist when version_id is non-blank.
    TSV=/path/to/file.tsv (default /app/tmp/projects_version_id2.tsv). DRY_RUN defaults to on; DRY_RUN=0 applies.
    VERBOSE=1 prints each change.
  DESC
  task revert_version_id_from_tsv: :environment do
    path = ENV.fetch("TSV", "/app/tmp/projects_version_id2.tsv")
    dry_run = ENV["DRY_RUN"] != "0"
    verbose = ENV["VERBOSE"] == "1"

    unless File.file?(path)
      warn "[projects:revert_version_id_from_tsv] error: file not found: #{path}"
      exit 1
    end

    counts = Hash.new(0)

    File.foreach(path, encoding: "UTF-8") do |line|
      line = line.chomp
      next if line.empty?

      # -1 keeps trailing empty fields (TSV rows with empty version_id stay 3 columns).
      parts = line.split("\t", -1)
      if parts[0] == "id" && parts[1].to_s == "key"
        counts[:header] += 1
        next
      end
      if parts.size < 3
        counts[:skip_bad_line] += 1
        next
      end

      id_s = parts[0].to_s
      key_s = parts[1].to_s
      vid_s = parts[2].to_s.strip

      pid = id_s.to_i
      if pid <= 0
        counts[:skip_bad_id] += 1
        next
      end

      target_vid = vid_s.empty? ? nil : vid_s.to_i

      if target_vid.present? && !Version.exists?(id: target_vid)
        warn "[projects:revert_version_id_from_tsv] error: version_id #{target_vid} not in database (project id=#{pid} key=#{key_s})"
        exit 1
      end

      project = Project.find_by(id: pid)
      unless project
        counts[:skip_missing_project] += 1
        next
      end

      if project.key.to_s != key_s
        warn "[projects:revert_version_id_from_tsv] error: key mismatch id=#{pid} file_key=#{key_s.inspect} db_key=#{project.key.inspect}"
        exit 1
      end

      if project.version_id == target_vid
        counts[:skip_no_change] += 1
        next
      end

      if verbose
        puts "  id=#{pid} key=#{key_s} #{project.version_id.inspect} -> #{target_vid.inspect}"
      end

      if dry_run
        counts[:would_update] += 1
      else
        project.update_column(:version_id, target_vid)
        counts[:updated] += 1
      end
    end

    puts "[projects:revert_version_id_from_tsv] path=#{path} dry_run=#{dry_run}"
    puts "  #{counts.map { |k, v| "#{k}=#{v}" }.join(' ')}"
    puts "[projects:revert_version_id_from_tsv] done"
  end
end
