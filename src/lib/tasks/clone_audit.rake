namespace :clone do
  desc "Audit cloned projects for stale references. Usage: clone:audit[project_key,skip_archived]"
  task :audit, [:project_key, :skip_archived] => :environment do |t, args|
    user_data_dirs = ['/data/asap2/users', ENV.fetch('USER_DATA_DIR', '/data/asap2_test/users')]
    report_path = "/tmp/clone_audit_report_#{Time.now.strftime('%Y%m%d_%H%M%S')}.txt"
    skip_archived = args[:skip_archived].to_s == "true"

    projects_scope = Project.where.not(cloned_project_id: nil)
    if args[:project_key].present?
      projects_scope = projects_scope.where(key: args[:project_key])
    end
    if skip_archived
      projects_scope = projects_scope.where(archive_status_id: 1)
    end

    cloned_projects = projects_scope.order(:id).to_a
    if cloned_projects.empty?
      msg = args[:project_key].present? ? "No cloned project found with key '#{args[:project_key]}'" : "No cloned projects found in database"
      puts msg
      exit 0
    end

    all_steps = Step.all.index_by(&:id)
    all_statuses = Status.all.index_by(&:id)
    global_issues = { total: 0, by_type: Hash.new(0), projects_with_issues: 0, projects_clean: 0, projects_source_missing: 0, projects_audited: 0 }

    # Prepare S3 connection once (needed for archive checks)
    s3_client = nil
    s3_bucket_key = nil
    begin
      h_s3_settings = Basic.get_s3_settings
      s3b = { key: '20000-af8a16d143d9920a26869b30700c3da4', endpoint: 'https://s3.epfl.ch', region: 'us-west-2' }
      s3_client = Basic.connect_s3(s3b, h_s3_settings)
      s3_bucket_key = s3b[:key]
    rescue => e
      puts "WARNING: Could not connect to S3: #{e.message}"
      puts "Archived projects will be skipped for disk analysis."
    end

    File.open(report_path, "w") do |report|
      header = <<~HEADER
        #{'=' * 100}
        Clone Audit Report
        #{'=' * 100}
        Date: #{Time.now}
        Data directories: #{user_data_dirs.join(', ')}
        Skip archived: #{skip_archived}
        Projects to audit: #{cloned_projects.size}
        Report file: #{report_path}

      HEADER
      write_both(report, header)

      cloned_projects.each_with_index do |clone, idx|
        source = Project.find_by(id: clone.cloned_project_id)
        progress = "[#{idx + 1}/#{cloned_projects.size}]"

        project_header = <<~PROJ
          #{'-' * 100}
          #{progress} PROJECT: #{clone.key} (ID: #{clone.id})
            Source: #{source ? "#{source.key} (ID: #{source.id})" : "MISSING (ID: #{clone.cloned_project_id})"}
            Owner: user_id=#{clone.user_id}, Source owner: #{source&.user_id || 'N/A'}
            Status: #{all_statuses[clone.status_id]&.name || clone.status_id}
            Archive status: #{clone.archive_status_id}
            Created: #{clone.created_at}
        PROJ
        write_both(report, project_header)

        global_issues[:projects_audited] += 1
        issues = []

        unless source
          issues << { type: :source_missing, msg: "Source project ID #{clone.cloned_project_id} no longer exists" }
          global_issues[:projects_source_missing] += 1
          write_issues(report, issues, global_issues)
          next
        end

        # --- Build ID mappings from DB ---
        source_runs = Run.where(project_id: source.id).index_by(&:id)
        clone_runs = Run.where(project_id: clone.id).to_a
        source_annots = Annot.where(project_id: source.id).index_by(&:id)
        clone_annots = Annot.where(project_id: clone.id).to_a

        run_map = {}
        clone_runs.each { |cr| run_map[cr.cloned_run_id] = cr if cr.cloned_run_id }

        annot_map = {}
        clone_annots.each do |ca|
          source_annots.each_value do |sa|
            if sa.name == ca.name && sa.project_id == source.id && ca.project_id == clone.id
              if sa.run_id.nil? || (run_map[sa.run_id] && run_map[sa.run_id].id == ca.run_id)
                annot_map[sa.id] = ca
                break
              end
            end
          end
        end

        # === DB-level checks ===
        check_reqs(source, clone, clone_runs, issues)
        check_articles(source, clone, issues)
        check_pipeline_parent_run_ids(clone_runs, source_runs, issues)
        check_run_children_json(clone_runs, source_runs, issues)
        check_fo_filepaths(clone, source, source_runs, issues)
        check_annot_filepaths(clone_annots, source, source_runs, issues)
        check_run_json_fields(clone_runs, source, source_runs, run_map, issues)
        check_fu_id(clone, source, issues)

        # === Disk-level checks ===
        clone_dir = user_data_dirs
          .map { |d| Pathname.new(d) + clone.user_id.to_s + clone.key }
          .find { |d| File.exist?(d) }
        was_archived = false

        if clone_dir
          audit_disk(clone_dir, source, source_runs, run_map, clone_runs, issues)
        elsif clone.archive_status_id == 3 && s3_client
          # Project is archived on S3 -- temporarily unarchive for disk analysis
          write_both(report, "  Unarchiving from S3 for disk analysis...")
          was_archived = true
          begin
            Basic.unarchive(clone.key)
            clone.reload
            # After unarchive, find the directory again
            clone_dir = user_data_dirs
              .map { |d| Pathname.new(d) + clone.user_id.to_s + clone.key }
              .find { |d| File.exist?(d) }
            if clone_dir
              audit_disk(clone_dir, source, source_runs, run_map, clone_runs, issues)
            else
              issues << { type: :unarchive_failed, msg: "Unarchive completed but directory still not found" }
            end
          rescue => e
            issues << { type: :unarchive_error, msg: "Failed to unarchive: #{e.class} - #{e.message}" }
          end
        elsif clone.archive_status_id == 3
          issues << { type: :clone_dir_archived_no_s3, msg: "Project archived (status=3) but S3 not available for disk analysis" }
        else
          tried = user_data_dirs.map { |d| Pathname.new(d) + clone.user_id.to_s + clone.key }.join(', ')
          issues << { type: :clone_dir_missing, msg: "Clone directory not found (archive_status=#{clone.archive_status_id}). Checked: #{tried}" }
        end

        write_issues(report, issues, global_issues)

        # --- Cleanup: re-archive if we unarchived ---
        if was_archived && File.exist?(clone_dir)
          cleanup_after_audit(report, s3_client, s3_bucket_key, clone, clone_dir)
        end
      end

      # --- Global summary ---
      summary = <<~SUMMARY

        #{'=' * 100}
        GLOBAL SUMMARY
        #{'=' * 100}
        Total cloned projects audited: #{global_issues[:projects_audited]}
        Projects with issues: #{global_issues[:projects_with_issues]}
        Projects clean: #{global_issues[:projects_clean]}
        Projects with missing source: #{global_issues[:projects_source_missing]}
        Total issues found: #{global_issues[:total]}

      SUMMARY
      write_both(report, summary)

      if global_issues[:by_type].any?
        write_both(report, "Issues by type:")
        global_issues[:by_type].sort_by { |_, v| -v }.each do |type, count|
          write_both(report, "  %-50s %d" % [type, count])
        end
      else
        write_both(report, "No issues found.")
      end

      write_both(report, "")
      write_both(report, "=" * 100)
      write_both(report, "Report saved to: #{report_path}")
      write_both(report, "=" * 100)
    end
  end
end

# ============================================================================
# DB-level checks
# ============================================================================

def check_reqs(source, clone, clone_runs, issues)
  source_reqs = Req.where(project_id: source.id).to_a
  clone_reqs = Req.where(project_id: clone.id).to_a

  if source_reqs.any? && clone_reqs.empty?
    issues << { type: :reqs_not_cloned, msg: "Source has #{source_reqs.size} Req(s) but clone has none" }
  end

  source_req_ids = source_reqs.map(&:id).to_set
  clone_runs.each do |cr|
    next unless cr.req_id
    if source_req_ids.include?(cr.req_id)
      issues << { type: :run_req_id_stale, msg: "Run##{cr.id} req_id=#{cr.req_id} belongs to source project" }
    elsif !Req.exists?(cr.req_id)
      issues << { type: :run_req_id_dangling, msg: "Run##{cr.id} req_id=#{cr.req_id} does not exist" }
    end
  end
end

def check_articles(source, clone, issues)
  source_article_ids = source.articles.pluck(:id).sort
  clone_article_ids = clone.articles.pluck(:id).sort
  missing = source_article_ids - clone_article_ids
  if missing.any?
    issues << { type: :articles_not_cloned, msg: "Missing #{missing.size}/#{source_article_ids.size} article associations: #{missing.first(10).join(', ')}#{missing.size > 10 ? '...' : ''}" }
  end
end

def check_pipeline_parent_run_ids(clone_runs, source_runs, issues)
  clone_runs.each do |cr|
    next if cr.pipeline_parent_run_ids.blank?
    ids = cr.pipeline_parent_run_ids.split(",").map(&:strip).reject(&:empty?).map(&:to_i)
    stale = ids.select { |id| source_runs.key?(id) }
    if stale.any?
      issues << { type: :pipeline_parent_ids_stale, msg: "Run##{cr.id} pipeline_parent_run_ids has source run IDs: #{stale.join(', ')}" }
    end
  end
end

def check_run_children_json(clone_runs, source_runs, issues)
  clone_runs.each do |cr|
    next if cr.run_children_json.blank?
    json_str = cr.run_children_json
    stale = source_runs.keys.select { |src_id| json_str.include?(src_id.to_s) }
    if stale.any?
      issues << { type: :run_children_json_stale, msg: "Run##{cr.id} run_children_json references source run IDs: #{stale.first(5).join(', ')}#{stale.size > 5 ? '...' : ''}" }
    end
  end
end

def check_fo_filepaths(clone, source, source_runs, issues)
  source_key = source.key
  source_only_run_ids = source_runs.keys.map(&:to_s)

  Fo.where(project_id: clone.id).find_each do |fo|
    next unless fo.filepath.present?
    if fo.filepath.include?(source_key)
      issues << { type: :fo_filepath_source_key, msg: "Fo##{fo.id} filepath contains source key '#{source_key}': #{fo.filepath}" }
    end
    source_only_run_ids.each do |src_id|
      if fo.filepath.match?(%r{/#{src_id}(?:/|$)})
        issues << { type: :fo_filepath_source_run_id, msg: "Fo##{fo.id} filepath has source run_id /#{src_id}/: #{fo.filepath}" }
        break
      end
    end
  end
end

def check_annot_filepaths(clone_annots, source, source_runs, issues)
  source_key = source.key
  source_only_run_ids = source_runs.keys.map(&:to_s)

  clone_annots.each do |annot|
    next unless annot.filepath.present?
    if annot.filepath.include?(source_key)
      issues << { type: :annot_filepath_source_key, msg: "Annot##{annot.id} (#{annot.name}) filepath contains source key '#{source_key}': #{annot.filepath}" }
    end
    source_only_run_ids.each do |src_id|
      if annot.filepath.match?(%r{/#{src_id}(?:/|$)})
        issues << { type: :annot_filepath_source_run_id, msg: "Annot##{annot.id} (#{annot.name}) filepath has source run_id /#{src_id}/: #{annot.filepath}" }
        break
      end
    end
  end
end

def check_run_json_fields(clone_runs, source, source_runs, run_map, issues)
  clone_runs.each do |cr|
    if cr.command_json.present?
      if cr.command_json.include?(source.key)
        issues << { type: :run_command_source_key, msg: "Run##{cr.id} command_json contains source key '#{source.key}'" }
      end
      source_runs.each_key do |src_id|
        next if run_map[src_id]&.id&.to_s == src_id.to_s
        if cr.command_json.match?(%r{[/_":]#{src_id}[/_":]})
          issues << { type: :run_command_source_run_id, msg: "Run##{cr.id} command_json references source run_id #{src_id}" }
          break
        end
      end
    end

    if cr.attrs_json.present? && cr.attrs_json != "{}"
      if cr.attrs_json.include?(source.key)
        issues << { type: :run_attrs_source_key, msg: "Run##{cr.id} attrs_json contains source key '#{source.key}'" }
      end
    end

    if cr.output_json.present? && cr.output_json != "{}"
      if cr.output_json.include?(source.key)
        issues << { type: :run_output_source_key, msg: "Run##{cr.id} output_json contains source key '#{source.key}'" }
      end
    end
  end
end

def check_fu_id(clone, source, issues)
  return unless clone.fu_id.present?
  fu = Fu.find_by(id: clone.fu_id)
  if fu
    if fu.project_id.present? && fu.project_id == source.id
      # Expected per design - report as info, not issue
    end
  else
    issues << { type: :fu_id_dangling, msg: "Project.fu_id=#{clone.fu_id} references a Fu that no longer exists" }
  end
end

# ============================================================================
# Disk-level checks
# ============================================================================

def audit_disk(clone_dir, source, source_runs, run_map, clone_runs, issues)
  source_key = source.key
  source_user_dir_fragment = "/#{source.user_id}/#{source.key}/"
  source_run_ids_str = source_runs.keys.map(&:to_s)
  clone_run_ids_str = clone_runs.map { |r| r.id.to_s }
  source_only_run_ids = source_run_ids_str - clone_run_ids_str

  # Check cxg_validation_result.json
  validation_file = clone_dir + "cxg_validation_result.json"
  if File.exist?(validation_file)
    issues << { type: :cxg_validation_carried_over, msg: "cxg_validation_result.json exists (should be regenerated after clone)" }
    begin
      content = File.read(validation_file, encoding: 'utf-8')
      if content.include?(source_key)
        issues << { type: :cxg_validation_source_ref, msg: "cxg_validation_result.json references source key '#{source_key}'" }
      end
    rescue => e
      issues << { type: :file_read_error, msg: "Could not read cxg_validation_result.json: #{e.message}" }
    end
  end

  # Scan text files for source references
  file_count = 0
  scanned_count = 0
  files_with_source_key = []
  files_with_source_path = []
  files_with_source_run_id = []

  Dir.glob(File.join(clone_dir, "**", "*")).each do |filepath|
    next unless File.file?(filepath)
    file_count += 1
    next if binary_file?(filepath)
    next if File.size(filepath) > 5 * 1024 * 1024
    scanned_count += 1

    begin
      content = File.read(filepath, encoding: 'utf-8')
    rescue
      next
    end

    rel_path = Pathname.new(filepath).relative_path_from(clone_dir).to_s

    if content.include?(source_key)
      files_with_source_key << rel_path
    end

    if content.include?(source_user_dir_fragment)
      files_with_source_path << rel_path
    end

    source_only_run_ids.each do |src_id|
      if content.match?(%r{/#{Regexp.escape(src_id)}/})
        files_with_source_run_id << "#{rel_path} (run_id #{src_id})"
        break
      end
    end
  end

  if files_with_source_key.any?
    issues << { type: :files_with_source_key, msg: "#{files_with_source_key.size} file(s) contain source key '#{source_key}': #{files_with_source_key.first(10).join(', ')}#{files_with_source_key.size > 10 ? '...' : ''}" }
  end
  if files_with_source_path.any?
    issues << { type: :files_with_source_path, msg: "#{files_with_source_path.size} file(s) contain source path '#{source_user_dir_fragment}': #{files_with_source_path.first(10).join(', ')}#{files_with_source_path.size > 10 ? '...' : ''}" }
  end
  if files_with_source_run_id.any?
    issues << { type: :files_with_source_run_id, msg: "#{files_with_source_run_id.size} file(s) contain source-only run IDs in paths: #{files_with_source_run_id.first(10).join(', ')}#{files_with_source_run_id.size > 10 ? '...' : ''}" }
  end

  # Check for directories named after source run IDs
  Dir.glob(File.join(clone_dir, "*")).each do |step_dir_path|
    next unless File.directory?(step_dir_path)
    step_name = File.basename(step_dir_path)

    Dir.glob(File.join(step_dir_path, "*")).each do |sub_dir|
      next unless File.directory?(sub_dir)
      dir_name = File.basename(sub_dir)
      next unless dir_name.match?(/\A\d+\z/)

      if source_only_run_ids.include?(dir_name)
        issues << { type: :dir_named_source_run_id, msg: "#{step_name}/#{dir_name}/ named after source run_id (not renamed)" }
      end
    end
  end

  # List all files for completeness
  issues << { type: :disk_scan_info, msg: "#{file_count} files total, #{scanned_count} text files scanned in #{clone_dir}" }
end

# ============================================================================
# Archive cleanup
# ============================================================================

def cleanup_after_audit(report, s3_client, s3_bucket_key, clone, clone_dir)
  # Verify data is still on S3 before removing local copy
  begin
    s3_client.head_object(bucket: s3_bucket_key, key: clone.key)
    write_both(report, "  S3 object verified for '#{clone.key}'. Removing local data and restoring archive status...")

    FileUtils.rm_rf(clone_dir)
    clone.update_columns(archive_status_id: 3)
    write_both(report, "  Cleanup done: local data removed, archive_status_id restored to 3.")
  rescue Aws::S3::Errors::NotFound
    write_both(report, "  WARNING: S3 object NOT found for '#{clone.key}'. Keeping local data to avoid data loss.")
    # Leave archive_status_id as-is (1, set by unarchive)
  rescue => e
    write_both(report, "  WARNING: S3 verification failed (#{e.class}: #{e.message}). Keeping local data.")
  end
end

# ============================================================================
# Helpers
# ============================================================================

def binary_file?(filepath)
  ext = File.extname(filepath).downcase
  %w[
    .loom .h5 .h5ad .hdf5 .rds .robj .rdata
    .png .jpg .jpeg .gif .svg .pdf .ico
    .gz .tar .zip .bz2 .xz .7z
    .bin .dat .npy .npz .pkl .pickle
    .so .dylib .o .a
    .woff .woff2 .ttf .eot
    .sqlite3 .db
  ].include?(ext)
end

def write_both(report, text)
  puts text
  report.puts text
  report.flush
end

def write_issues(report, issues, global_issues)
  # Filter out info-only items for counting
  real_issues = issues.reject { |i| i[:type] == :disk_scan_info }

  if real_issues.empty?
    write_both(report, "  No issues found.\n")
    global_issues[:projects_clean] += 1
  else
    global_issues[:projects_with_issues] += 1
    write_both(report, "  Issues (#{real_issues.size}):")
    issues.each do |issue|
      prefix = issue[:type] == :disk_scan_info ? "  INFO" : "  ISSUE"
      write_both(report, "    [#{issue[:type]}] #{issue[:msg]}")
      global_issues[:by_type][issue[:type]] += 1
    end
    global_issues[:total] += real_issues.size
    write_both(report, "")
  end
end
