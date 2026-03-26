require 'fileutils'
require 'find'
require 'open3'
require 'pathname'

namespace :storage do
  def bytes_to_human(n)
    n = n.to_i
    return "0 B" if n <= 0

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

  def path_size_bytes(path)
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

  def safe_children(dir)
    Dir.children(dir.to_s)
  rescue StandardError => e
    puts "[storage:audit_users_dir] WARNING: could not list #{dir} (#{e.class}: #{e.message})"
    []
  end

  def assert_backup_dir_usable!(backup_root)
    br = Pathname.new(backup_root)
    raise "BACKUP_DIR must be absolute: #{br}" unless br.absolute?

    if File.directory?(br.to_s)
      raise "BACKUP_DIR is not writable: #{br}" unless File.writable?(br.to_s)

      return
    end

    raise "BACKUP_DIR exists but is not a directory: #{br}" if File.exist?(br.to_s)

    parent = br.parent
    unless File.directory?(parent.to_s)
      raise "BACKUP_DIR parent must exist (e.g. mount #{parent} on the host): #{parent}"
    end
    unless File.writable?(parent.to_s)
      raise "BACKUP_DIR parent is not writable: #{parent}"
    end

    FileUtils.mkdir_p(br.to_s)
    raise "BACKUP_DIR is not writable after create: #{br}" unless File.writable?(br.to_s)
  end

  def move_path_across_filesystems(src, dest)
    dest_parent = File.dirname(dest)
    if File.lstat(src).dev == File.stat(dest_parent).dev
      FileUtils.mv(src, dest)
      return
    end

    cross_device_copy_then_remove(src, dest)
  end

  # -L: follow symlinks on the source so the destination never needs to store symlinks (many backup
  # filesystems return ENOTSUP for symlink(2), e.g. some NFS/CIFS exports).
  # With -L, dangling symlinks cannot be copied; rsync exits 23. We treat that as success when every
  # non-summary line is only "symlink has no referent" (nothing else failed).
  def rsync_exit_23_only_broken_symlinks?(combined)
    lines = combined.lines.map(&:strip).reject(&:empty?)
    return false if lines.empty?

    meaningful = lines.reject do |line|
      line.match?(/rsync error:.*code 23/i) ||
        line.match?(/some files\/attrs were not transferred/i)
    end

    return false if meaningful.empty?

    meaningful.all? { |l| l.match?(/symlink has no referent:/i) }
  end

  def rsync_cross_device_copy(src, dest)
    args = ['rsync', '-aH', '-L', '--checksum']
    argv = if File.directory?(src)
      args + ["#{src}/", "#{dest}/"]
    else
      args + [src, dest]
    end

    stdout, stderr, status = Open3.capture3(*argv)
    combined = stdout + stderr
    $stdout.print(stdout) unless stdout.empty?
    $stderr.print(stderr) unless stderr.empty?

    return true if status.success?

    return false unless status.exitstatus == 23

    unless rsync_exit_23_only_broken_symlinks?(combined)
      return false
    end

    puts "[storage:audit_users_dir] NOTE: rsync exit 23 accepted (only broken symlinks under -L)"
    true
  end

  def cross_device_copy_then_remove(src, dest)
    FileUtils.rm_rf(dest) if File.exist?(dest)

    unless rsync_cross_device_copy(src, dest)
      raise "cross-device move failed (rsync -aHL --checksum): src=#{src} dest=#{dest}"
    end

    FileUtils.rm_rf(src)
  end

  def move_candidate_to_backup(src, users_root, backup_root)
    src_pn = Pathname.new(src)
    rel = src_pn.relative_path_from(users_root)
    dest = backup_root + rel
    raise "refusing to move: path is not under users_dir (#{users_root}): #{src}" if rel.to_s.start_with?('..')

    if File.exist?(dest.to_s)
      if File.exist?(src_pn.to_s)
        puts "[storage:audit_users_dir] NOTE: destination exists; removing stale backup and redoing move: #{dest}"
        FileUtils.rm_rf(dest.to_s)
      else
        puts "[storage:audit_users_dir] NOTE: skipping move (source already absent, backup present): #{dest}"
        return dest.to_s
      end
    end

    FileUtils.mkdir_p(dest.parent.to_s)
    move_path_across_filesystems(src_pn.to_s, dest.to_s)
    dest.to_s
  end

  desc "Audit users storage tree for removable leftovers and estimate reclaimable bytes. " \
       "Scan root: USERS_DIR if set, else USER_DATA_DIR (same as project on-disk layout), else /data/asap/users. " \
       "With MOVE=1, move each reported candidate under BACKUP_DIR (default /mnt/asap-backup/old_users_data; " \
       "created if missing when the parent path exists and is writable), " \
       "preserving the path relative to the users root. " \
       "Usage: rake storage:audit_users_dir [USERS_DIR=...] [TOP=50] [LIMIT_USERS=] [LIMIT_PROJECTS=] [MOVE=1] [BACKUP_DIR=...]"
  task audit_users_dir: :environment do
    users_dir = ENV['USERS_DIR'].presence || ENV.fetch('USER_DATA_DIR', '/data/asap/users')
    top_n = ENV.fetch('TOP', '50').to_i
    limit_users = ENV['LIMIT_USERS']&.to_i
    limit_projects = ENV['LIMIT_PROJECTS']&.to_i

    root = Pathname.new(users_dir)
    raise "USERS_DIR does not exist: #{root}" unless File.directory?(root)

    puts "[storage:audit_users_dir] start users_dir=#{root} top=#{top_n} limit_users=#{limit_users.inspect} limit_projects=#{limit_projects.inspect}"

    totals = Hash.new(0)
    candidates = [] # {bytes:, type:, path:, user_id:, project_key:, project_id:, archive_status_id:}

    user_dirs = safe_children(root)
      .map { |name| root + name }
      .select { |p| File.directory?(p) }
      .sort_by(&:to_s)

    user_dirs = user_dirs.first(limit_users) if limit_users && limit_users > 0

    user_dirs.each do |user_path|
      user_id_str = user_path.basename.to_s
      next unless user_id_str.match?(/\A\d+\z/)

      user_id = user_id_str.to_i
      entries = safe_children(user_path).sort
      entries = entries.first(limit_projects) if limit_projects && limit_projects > 0

      entries.each do |entry|
        full = user_path + entry

        if File.file?(full) && entry.end_with?('.tgz')
          key = entry.sub(/\.tgz\z/, '')
          project = Project.find_by(user_id: user_id, key: key)
          bytes = path_size_bytes(full)
          next if bytes <= 0

          type =
            if project.nil?
              :orphan_archive_file_deleted_project
            elsif project.archived_on_s3?
              :archive_file_for_archived_project
            else
              :archive_file_for_unarchived_project
            end

          totals[type] += bytes
          candidates << {
            bytes: bytes,
            type: type,
            path: full.to_s,
            user_id: user_id,
            project_key: key,
            project_id: project&.id,
            archive_status_id: project&.archive_status_id
          }
          next
        end

        next unless File.directory?(full)

        project_key = entry
        project = Project.find_by(user_id: user_id, key: project_key)
        bytes = path_size_bytes(full)
        next if bytes <= 0

        type =
          if project.nil?
            :orphan_project_dir_deleted_project
          elsif project.archived_on_s3?
            :local_dir_present_for_archived_project
          elsif project.being_deleted
            :local_dir_for_being_deleted_project
          else
            :kept
          end

        totals[:scanned_project_dir_bytes] += bytes
        totals[:scanned_project_dir_count] += 1

        next if type == :kept

        totals[type] += bytes
        candidates << {
          bytes: bytes,
          type: type,
          path: full.to_s,
          user_id: user_id,
          project_key: project_key,
          project_id: project&.id,
          archive_status_id: project&.archive_status_id
        }
      end
    end

    reclaimable = candidates.sum { |c| c[:bytes].to_i }

    puts ""
    puts "[storage:audit_users_dir] SUMMARY"
    puts "  scanned_project_dir_count=#{totals[:scanned_project_dir_count]}"
    puts "  scanned_project_dir_bytes=#{bytes_to_human(totals[:scanned_project_dir_bytes])} (#{totals[:scanned_project_dir_bytes]})"
    puts "  reclaimable_bytes=#{bytes_to_human(reclaimable)} (#{reclaimable})"
    puts ""

    report_types = %i[
      local_dir_present_for_archived_project
      orphan_project_dir_deleted_project
      local_dir_for_being_deleted_project
      archive_file_for_archived_project
      orphan_archive_file_deleted_project
      archive_file_for_unarchived_project
    ]

    report_types.each do |t|
      next unless totals[t].to_i.positive?

      puts "  #{t}=#{bytes_to_human(totals[t])} (#{totals[t]})"
    end

    puts ""
    puts "[storage:audit_users_dir] TOP #{top_n} candidates by size"
    puts "  (type bytes human user_id project_key project_id archive_status_id path)"

    candidates
      .sort_by { |c| -c[:bytes].to_i }
      .first([top_n, 0].max)
      .each do |c|
        puts "  #{c[:type]} #{c[:bytes]} #{bytes_to_human(c[:bytes])} #{c[:user_id]} #{c[:project_key]} #{c[:project_id] || '-'} #{c[:archive_status_id] || '-'} #{c[:path]}"
      end

    if ENV['MOVE'] == '1'
      backup_root = Pathname.new(ENV.fetch('BACKUP_DIR', '/mnt/asap-backup/old_users_data'))
      assert_backup_dir_usable!(backup_root)

      puts ""
      puts "[storage:audit_users_dir] MOVE: #{candidates.size} path(s) -> #{backup_root}"

      moved = 0
      moved_bytes = 0
      candidates.sort_by { |c| -c[:bytes].to_i }.each do |c|
        dest = move_candidate_to_backup(c[:path], root, backup_root)
        puts "  moved #{c[:type]} #{bytes_to_human(c[:bytes])} #{c[:path]} -> #{dest}"
        moved += 1
        moved_bytes += c[:bytes].to_i
      end

      puts "[storage:audit_users_dir] MOVE done: #{moved} path(s), #{moved_bytes} bytes (#{bytes_to_human(moved_bytes)})"
    end

    puts ""
    puts "[storage:audit_users_dir] done"
  end
end

