# frozen_string_literal: true

require 'fileutils'
require 'find'
require 'pathname'

namespace :storage do
  def orphan_project_bytes_to_human(n)
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

  def orphan_project_path_size_bytes(path)
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

  def orphan_project_safe_children(dir)
    Dir.children(dir.to_s)
  rescue StandardError => e
    puts "[storage:remove_orphan_project_dirs] WARNING: could not list #{dir} (#{e.class}: #{e.message})"
    []
  end

  # Same guard as Project#remove_project_filesystem_after_destroy!: only a path under
  # USER_DATA_DIR whose basename is the project key.
  def orphan_project_path_safe?(root:, path:, expected_basename:)
    root_pn = Pathname.new(root).cleanpath
    path_pn = Pathname.new(path).cleanpath
    return false if expected_basename.blank?
    return false unless path_pn.to_s.start_with?("#{root_pn}/")
    return false if path_pn.to_s == root_pn.to_s

    path_pn.basename.to_s == expected_basename
  end

  desc 'List or delete leftover USER_DATA_DIR/<user_id>/<project_key>/ trees (and sibling .tgz) ' \
       'that have no matching Project row. Dry-run by default; set DELETE=1 to remove. ' \
       'Usage: rake storage:remove_orphan_project_dirs [USERS_DIR=...] [DELETE=1] [LIMIT_USERS=] [TOP=100]'
  task remove_orphan_project_dirs: :environment do
    users_dir = ENV['USERS_DIR'].presence || ENV.fetch('USER_DATA_DIR') do
      raise 'USER_DATA_DIR is not set (or pass USERS_DIR=...)'
    end
    delete_mode = ENV['DELETE'].to_s == '1'
    top_n = ENV.fetch('TOP', '100').to_i
    limit_users = ENV['LIMIT_USERS']&.to_i

    root = Pathname.new(users_dir).cleanpath
    raise "USERS_DIR does not exist: #{root}" unless File.directory?(root.to_s)

    puts "[storage:remove_orphan_project_dirs] start users_dir=#{root} delete=#{delete_mode} top=#{top_n}"

    candidates = []

    user_dirs = orphan_project_safe_children(root)
      .select { |name| name.match?(/\A\d+\z/) && File.directory?((root + name).to_s) }
      .sort_by(&:to_i)

    user_dirs = user_dirs.first(limit_users) if limit_users && limit_users.positive?

    user_ids = user_dirs.map(&:to_i)
    projects_by_user_and_key = {}
    if user_ids.any?
      Project.where(user_id: user_ids).pluck(:user_id, :key).each do |uid, key|
        projects_by_user_and_key[[uid, key]] = true
      end
    end

    user_dirs.each do |user_id_str|
      user_id = user_id_str.to_i
      user_path = root + user_id_str

      orphan_project_safe_children(user_path).each do |entry_name|
        full = user_path + entry_name

        if File.directory?(full.to_s)
          project_key = entry_name
          next if projects_by_user_and_key[[user_id, project_key]]

          unless orphan_project_path_safe?(root: root, path: full, expected_basename: project_key)
            puts "[storage:remove_orphan_project_dirs] SKIP unsafe path #{full}"
            next
          end

          bytes = orphan_project_path_size_bytes(full)
          candidates << {
            kind: :dir,
            bytes: bytes,
            path: full.to_s,
            user_id: user_id,
            project_key: project_key
          }
        elsif File.file?(full.to_s) && entry_name.end_with?('.tgz')
          project_key = entry_name.sub(/\.tgz\z/, '')
          next if projects_by_user_and_key[[user_id, project_key]]

          unless orphan_project_path_safe?(root: root, path: full, expected_basename: entry_name)
            puts "[storage:remove_orphan_project_dirs] SKIP unsafe path #{full}"
            next
          end

          bytes = File.size(full).to_i
          candidates << {
            kind: :tgz,
            bytes: bytes,
            path: full.to_s,
            user_id: user_id,
            project_key: project_key
          }
        end
      end
    end

    total_bytes = candidates.sum { |c| c[:bytes].to_i }
    dir_count = candidates.count { |c| c[:kind] == :dir }
    tgz_count = candidates.count { |c| c[:kind] == :tgz }

    puts ''
    puts '[storage:remove_orphan_project_dirs] summary'
    puts "  orphan_project_dirs: #{dir_count}"
    puts "  orphan_archive_tgz: #{tgz_count}"
    puts "  total_candidates: #{candidates.size}"
    puts "  total_size: #{orphan_project_bytes_to_human(total_bytes)} (#{total_bytes} bytes)"

    if candidates.empty?
      puts '[storage:remove_orphan_project_dirs] nothing to do'
      next
    end

    puts ''
    puts "[storage:remove_orphan_project_dirs] candidates (sorted by size, top #{top_n})"
    puts '  kind bytes human user_id project_key path'
    candidates.sort_by { |c| -c[:bytes].to_i }.first([top_n, 0].max).each do |c|
      puts "  #{c[:kind]} #{c[:bytes]} #{orphan_project_bytes_to_human(c[:bytes])} " \
           "#{c[:user_id]} #{c[:project_key]} #{c[:path]}"
    end
    if candidates.size > top_n
      puts "  ... (#{candidates.size - top_n} more not shown)"
    end

    unless delete_mode
      puts ''
      puts '[storage:remove_orphan_project_dirs] dry-run only. To delete these paths, re-run with DELETE=1'
      next
    end

    puts ''
    puts "[storage:remove_orphan_project_dirs] DELETE=1: removing #{candidates.size} path(s)"
    removed = 0
    removed_bytes = 0
    failed = 0

    candidates.sort_by { |c| -c[:bytes].to_i }.each do |c|
      unless orphan_project_path_safe?(
        root: root,
        path: c[:path],
        expected_basename: c[:kind] == :tgz ? "#{c[:project_key]}.tgz" : c[:project_key]
      )
        puts "  REFUSED unsafe #{c[:path]}"
        failed += 1
        next
      end

      # Re-check DB immediately before delete in case a project was created during the scan.
      if Project.exists?(user_id: c[:user_id], key: c[:project_key])
        puts "  SKIP now has Project row: #{c[:path]}"
        next
      end

      if c[:kind] == :dir
        FileUtils.rm_rf(c[:path])
      else
        FileUtils.rm_f(c[:path])
      end
      puts "  removed #{c[:kind]} #{orphan_project_bytes_to_human(c[:bytes])} #{c[:path]}"
      removed += 1
      removed_bytes += c[:bytes].to_i
    rescue StandardError => e
      failed += 1
      $stderr.puts "  FAILED #{c[:path]}: #{e.class} #{e.message}"
    end

    puts ''
    puts "[storage:remove_orphan_project_dirs] done removed=#{removed} " \
         "removed_bytes=#{removed_bytes} (#{orphan_project_bytes_to_human(removed_bytes)}) failed=#{failed}"
  end
end
