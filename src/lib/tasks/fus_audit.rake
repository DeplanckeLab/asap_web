require 'find'
require 'fileutils'
require 'pathname'
namespace :fus do
  def fus_audit_root
    if ENV['UPLOAD_DATA_DIR'].present?
      ENV['UPLOAD_DATA_DIR']
    elsif ENV['DATA_DIR'].present?
      Pathname.new(ENV['DATA_DIR']).join('fus').to_s
    else
      '/data/asap2/fus'
    end
  end

  def fus_audit_bytes_to_human(n)
    n = n.to_i
    return '0 B' if n <= 0

    units = %w[B KB MB GB TB PB]
    idx = 0
    value = n.to_f
    while value >= 1024 && idx < units.size - 1
      value /= 1024.0
      idx += 1
    end
    formatted =
      if idx == 0
        value.to_i.to_s
      else
        format('%.2f', value)
      end
    "#{formatted} #{units[idx]}"
  end

  def fus_audit_dir_size_bytes(path)
    return 0 unless File.exist?(path)

    if File.file?(path)
      return File.size(path).to_i
    end

    total = 0
    Find.find(path.to_s) do |entry|
      next unless File.file?(entry)

      total += File.size(entry).to_i
    rescue StandardError
      next
    end
    total
  end

  def fus_audit_dir_safe?(root, path, fu_id)
    root_path = Pathname.new(root).cleanpath
    dir = Pathname.new(path).cleanpath
    return false unless dir.to_s.start_with?("#{root_path}/")
    return false if dir.to_s == root_path.to_s

    dir.basename.to_s == fu_id.to_s
  end

  # Linked if an existing Project is reachable via Fu.project_id, Fu.project_key,
  # or Project.fu_id. In-progress uploads (uploading/downloading) are not orphans:
  # they intentionally have no project yet (see fus:cleanup_stale_partial_uploads).
  def fus_audit_linked_to_existing_project?(fu, projects_by_id:, projects_by_key:, projects_by_fu_id:)
    return false unless fu
    return true if %w[uploading downloading].include?(fu.status)

    if fu.project_id.present? && projects_by_id[fu.project_id]
      return true
    end
    if fu.project_key.present? && projects_by_key[fu.project_key]
      return true
    end
    return true if projects_by_fu_id[fu.id]

    false
  end

  desc 'Audit the fus upload tree: list disk usage per Fu id, flag orphans. ' \
       'Orphans are numeric dirs with no Fu row, or a Fu row not linked to any existing ' \
       'project (via project_id, project_key, or Project.fu_id). ' \
       'In-progress uploading/downloading Fus are kept (use fus:cleanup_stale_partial_uploads). ' \
       'Dry-run by default. Set DELETE_ORPHANS=1 to remove orphan dirs and destroy leftover Fu rows. ' \
       'Cron example: DELETE_ORPHANS=1 bundle exec rake fus:audit. ' \
       'Root: UPLOAD_DATA_DIR, else DATA_DIR/fus, else /data/asap2/fus. Override with FUS_ROOT=...'
  task audit: :environment do
    root = Pathname.new(ENV['FUS_ROOT'].presence || fus_audit_root)
    delete_orphans = ENV['DELETE_ORPHANS'].to_s == '1'
    dry_run = !delete_orphans

    unless File.directory?(root.to_s)
      raise "fus root does not exist or is not a directory: #{root}"
    end

    puts "[fus:audit] root=#{root} dry_run=#{dry_run} delete_orphans=#{delete_orphans}"
    puts '[fus:audit] note: this scans the global upload staging root only (UPLOAD_DATA_DIR / DATA_DIR/fus). ' \
         'It does not look at project directories or count symlinks under USER_DATA_DIR.'

    entries = Dir.children(root.to_s)
    numeric_dirs = []
    other = []

    entries.each do |name|
      path = root + name
      if name.match?(/\A\d+\z/) && File.directory?(path.to_s)
        numeric_dirs << name.to_i
      else
        other << [name, path]
      end
    end

    numeric_dirs.sort!

    fus_by_id = numeric_dirs.empty? ? {} : Fu.where(id: numeric_dirs).index_by(&:id)

    project_ids = fus_by_id.values.map(&:project_id).compact.uniq
    project_keys = fus_by_id.values.map(&:project_key).select(&:present?).uniq
    projects_by_id = project_ids.empty? ? {} : Project.where(id: project_ids).index_by(&:id)
    projects_by_key = project_keys.empty? ? {} : Project.where(key: project_keys).index_by(&:key)
    projects_by_fu_id =
      if numeric_dirs.empty?
        {}
      else
        Project.where(fu_id: numeric_dirs).group_by(&:fu_id).transform_values(&:first)
      end

    orphan_rows = []
    linked_rows = []
    total_bytes = 0
    orphan_bytes = 0
    orphan_no_fu = 0
    orphan_unlinked = 0

    numeric_dirs.each do |fu_id|
      path = root + fu_id.to_s
      bytes = fus_audit_dir_size_bytes(path.to_s)
      total_bytes += bytes
      fu = fus_by_id[fu_id]

      if fus_audit_linked_to_existing_project?(
           fu,
           projects_by_id: projects_by_id,
           projects_by_key: projects_by_key,
           projects_by_fu_id: projects_by_fu_id
         )
        project =
          (fu.project_id.present? && projects_by_id[fu.project_id]) ||
          (fu.project_key.present? && projects_by_key[fu.project_key]) ||
          projects_by_fu_id[fu.id]
        linked_rows << {
          id: fu_id,
          bytes: bytes,
          status: fu.status,
          project_id: fu.project_id,
          project_key: fu.project_key,
          linked_project_id: project&.id,
          linked_project_key: project&.key,
          upload_file_name: fu.upload_file_name
        }
      else
        reason =
          if fu.nil?
            orphan_no_fu += 1
            'no_fu_row'
          else
            orphan_unlinked += 1
            'no_existing_project'
          end
        orphan_bytes += bytes
        orphan_rows << {
          id: fu_id,
          bytes: bytes,
          path: path.to_s,
          reason: reason,
          status: fu&.status,
          project_id: fu&.project_id,
          project_key: fu&.project_key,
          upload_file_name: fu&.upload_file_name,
          fu: fu
        }
      end
    end

    if numeric_dirs.empty?
      missing_scope = Fu.all
    else
      missing_scope = Fu.where.not(id: numeric_dirs)
    end
    missing_total = missing_scope.count
    missing_sample = missing_scope.order(:id).limit(50).pluck(:id)

    puts ''
    puts '[fus:audit] summary'
    puts "  numeric_upload_dirs: #{numeric_dirs.size}"
    puts "  total_size: #{fus_audit_bytes_to_human(total_bytes)} (#{total_bytes} bytes)"
    puts "  orphan_dirs: #{orphan_rows.size} " \
         "(no_fu_row=#{orphan_no_fu}, no_existing_project=#{orphan_unlinked})"
    puts "  orphan_size: #{fus_audit_bytes_to_human(orphan_bytes)} (#{orphan_bytes} bytes)"
    puts "  fu_rows_with_dir_linked_to_project: #{linked_rows.size}"
    puts "  fu_rows_missing_dir: #{missing_total}"

    if other.any?
      puts ''
      puts '[fus:audit] non-numeric or non-directory entries at root (not classified as orphans):'
      other.each do |name, path|
        type = File.directory?(path.to_s) ? 'dir' : 'file'
        puts "  #{name} (#{type})"
      end
    end

    if orphan_rows.any?
      puts ''
      puts '[fus:audit] orphan directories:'
      orphan_rows.sort_by { |r| -r[:bytes] }.each do |r|
        puts "  #{r[:id]}\t#{fus_audit_bytes_to_human(r[:bytes])}\treason=#{r[:reason]}\t" \
             "status=#{r[:status].inspect}\tproject_id=#{r[:project_id].inspect}\t" \
             "project_key=#{r[:project_key].inspect}\tfile=#{r[:upload_file_name].inspect}\t#{r[:path]}"
      end
    end

    if missing_total.positive?
      puts ''
      puts '[fus:audit] Fu ids in database with no directory under fus root (sample up to 50 ids):'
      missing_sample.each do |id|
        puts "  #{id}"
      end
      if missing_total > missing_sample.size
        puts "  ... (#{missing_total - missing_sample.size} more)"
      end
    end

    if linked_rows.any?
      puts ''
      puts '[fus:audit] directories linked to an existing project (sorted by size, top 30):'
      linked_rows.sort_by { |r| -r[:bytes] }.first(30).each do |r|
        puts "  #{r[:id]}\t#{fus_audit_bytes_to_human(r[:bytes])}\tstatus=#{r[:status].inspect}\t" \
             "project_id=#{r[:project_id].inspect}\tproject_key=#{r[:project_key].inspect}\t" \
             "linked_project=#{r[:linked_project_id].inspect}/#{r[:linked_project_key].inspect}\t" \
             "file=#{r[:upload_file_name].inspect}"
      end
      puts "  ... (#{linked_rows.size - 30} more rows not shown)" if linked_rows.size > 30
    end

    if dry_run
      puts ''
      if orphan_rows.empty?
        puts '[fus:audit] dry-run: nothing to remove'
      else
        puts "[fus:audit] dry-run: would remove #{orphan_rows.size} orphan director(y|ies)"
        orphan_rows.sort_by { |r| -r[:bytes] }.each do |r|
          fu_note = r[:fu] ? ' and destroy Fu row' : ''
          puts "  would remove #{r[:path]} (#{fus_audit_bytes_to_human(r[:bytes])}, #{r[:reason]})#{fu_note}"
        end
        puts '[fus:audit] dry-run only. To delete these paths, re-run with DELETE_ORPHANS=1'
      end
    elsif orphan_rows.empty?
      puts '[fus:audit] DELETE_ORPHANS=1: nothing to remove'
    else
      puts ''
      puts "[fus:audit] DELETE_ORPHANS=1: removing #{orphan_rows.size} orphan director(y|ies)"
      removed = 0
      removed_bytes = 0
      destroyed_fus = 0
      failed = 0

      orphan_rows.each do |r|
        unless fus_audit_dir_safe?(root, r[:path], r[:id])
          puts "  REFUSED unsafe path fu_id=#{r[:id]} path=#{r[:path]}"
          failed += 1
          next
        end

        if File.exist?(r[:path])
          FileUtils.rm_rf(r[:path])
        end

        fu = r[:fu] ? Fu.find_by(id: r[:id]) : nil
        if fu
          # Re-check: still not linked to an existing project.
          fresh_projects_by_id =
            fu.project_id.present? ? Project.where(id: fu.project_id).index_by(&:id) : {}
          fresh_projects_by_key =
            fu.project_key.present? ? Project.where(key: fu.project_key).index_by(&:key) : {}
          fresh_projects_by_fu_id =
            Project.where(fu_id: fu.id).index_by(&:fu_id)
          if fus_audit_linked_to_existing_project?(
               fu,
               projects_by_id: fresh_projects_by_id,
               projects_by_key: fresh_projects_by_key,
               projects_by_fu_id: fresh_projects_by_fu_id
             )
            puts "  SKIP no longer unlinked fu_id=#{fu.id} status=#{fu.status.inspect} " \
                 "project_id=#{fu.project_id.inspect} project_key=#{fu.project_key.inspect}"
            next
          end
          fu.destroy!
          destroyed_fus += 1
        end

        puts "  removed #{r[:path]} (#{r[:reason]})"
        removed += 1
        removed_bytes += r[:bytes].to_i
      rescue StandardError => e
        failed += 1
        $stderr.puts "  FAILED #{r[:path]}: #{e.class} #{e.message}"
      end

      puts ''
      puts "[fus:audit] done removed=#{removed} destroyed_fus=#{destroyed_fus} " \
           "removed_bytes=#{removed_bytes} (#{fus_audit_bytes_to_human(removed_bytes)}) failed=#{failed}"
    end

    puts ''
    puts '[fus:audit] done'
  end
end
