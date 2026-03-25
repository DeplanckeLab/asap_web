require 'find'
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

  desc "Audit users storage tree for removable leftovers and estimate reclaimable bytes. " \
       "Scan root: USERS_DIR if set, else USER_DATA_DIR (same as project on-disk layout), else /data/asap/users. " \
       "Usage: rake storage:audit_users_dir [USERS_DIR=...] [TOP=50] [LIMIT_USERS=] [LIMIT_PROJECTS=]"
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

    puts ""
    puts "[storage:audit_users_dir] done"
  end
end

