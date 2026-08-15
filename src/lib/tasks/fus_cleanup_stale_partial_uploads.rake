# frozen_string_literal: true

require 'fileutils'
require 'pathname'

namespace :fus do
  def stale_partial_bytes_to_human(n)
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

  def stale_partial_dir_size_bytes(path)
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

  def stale_partial_upload_dir_safe?(fu)
    root = Pathname.new(Fu.global_upload_root).cleanpath
    dir = fu.global_upload_dir.cleanpath
    return false unless dir.to_s.start_with?("#{root}/")
    return false if dir.to_s == root.to_s

    dir.basename.to_s == fu.id.to_s
  end

  desc 'List or delete unattached partial Fu uploads/downloads that went idle. ' \
       'Targets project_id IS NULL with status uploading|downloading and updated_at older than AGE_HOURS (default 12). ' \
       'Active chunk uploads refresh updated_at, so resume within the window is kept. Dry-run by default; set DELETE=1 to remove. ' \
       'Cron example: DELETE=1 AGE_HOURS=12 bundle exec rake fus:cleanup_stale_partial_uploads. ' \
       'Usage: rake fus:cleanup_stale_partial_uploads [AGE_HOURS=12] [DELETE=1] [TOP=50]'
  task cleanup_stale_partial_uploads: :environment do
    require 'find'

    age_hours = ENV.fetch('AGE_HOURS', '12').to_f
    raise 'AGE_HOURS must be > 0' unless age_hours.positive?

    delete_mode = ENV['DELETE'].to_s == '1'
    top_n = ENV.fetch('TOP', '50').to_i
    cutoff = age_hours.hours.ago
    lock_file = Pathname.new(Rails.root) + 'tmp' + 'cleanup_stale_partial_uploads.lock'
    FileUtils.mkdir_p(lock_file.dirname)

    File.open(lock_file, File::RDWR | File::CREAT, 0o644) do |lock|
      unless lock.flock(File::LOCK_EX | File::LOCK_NB)
        puts '[fus:cleanup_stale_partial_uploads] another run is already in progress; exiting'
        next
      end

      scope = Fu.where(project_id: nil, status: %w[uploading downloading])
                .where('updated_at < ?', cutoff)
                .order(:updated_at)

      puts "[fus:cleanup_stale_partial_uploads] start age_hours=#{age_hours} cutoff=#{cutoff.utc.iso8601} " \
           "delete=#{delete_mode} fus_root=#{Fu.global_upload_root}"

      candidates = []
      scope.find_each do |fu|
        dir = fu.global_upload_dir
        bytes = stale_partial_dir_size_bytes(dir.to_s)
        candidates << {
          fu: fu,
          bytes: bytes,
          path: dir.to_s,
          status: fu.status,
          updated_at: fu.updated_at,
          user_id: fu.user_id,
          url: fu.url
        }
      end

      total_bytes = candidates.sum { |c| c[:bytes].to_i }

      puts ''
      puts '[fus:cleanup_stale_partial_uploads] summary'
      puts "  candidates: #{candidates.size}"
      puts "  total_size: #{stale_partial_bytes_to_human(total_bytes)} (#{total_bytes} bytes)"

      if candidates.empty?
        puts '[fus:cleanup_stale_partial_uploads] nothing to do'
        next
      end

      puts ''
      puts "[fus:cleanup_stale_partial_uploads] candidates (oldest first, top #{top_n})"
      puts '  fu_id status updated_at_utc user_id bytes human path'
      candidates.first([top_n, 0].max).each do |c|
        puts "  #{c[:fu].id} #{c[:status]} #{c[:updated_at]&.utc&.iso8601} #{c[:user_id].inspect} " \
             "#{c[:bytes]} #{stale_partial_bytes_to_human(c[:bytes])} #{c[:path]}"
      end
      if candidates.size > top_n
        puts "  ... (#{candidates.size - top_n} more not shown)"
      end

      unless delete_mode
        puts ''
        puts '[fus:cleanup_stale_partial_uploads] dry-run only. To delete, re-run with DELETE=1'
        next
      end

      puts ''
      puts "[fus:cleanup_stale_partial_uploads] DELETE=1: removing #{candidates.size} Fu(s)"
      removed = 0
      removed_bytes = 0
      failed = 0

      candidates.each do |c|
        fu = Fu.find_by(id: c[:fu].id)
        unless fu
          puts "  SKIP already gone fu_id=#{c[:fu].id}"
          next
        end

        # Re-check eligibility immediately before delete.
        unless fu.project_id.nil? && %w[uploading downloading].include?(fu.status) && fu.updated_at < cutoff
          puts "  SKIP no longer stale fu_id=#{fu.id} status=#{fu.status.inspect} " \
               "project_id=#{fu.project_id.inspect} updated_at=#{fu.updated_at&.utc&.iso8601}"
          next
        end

        dir = fu.global_upload_dir
        if File.exist?(dir.to_s)
          unless stale_partial_upload_dir_safe?(fu)
            puts "  REFUSED unsafe path fu_id=#{fu.id} path=#{dir}"
            failed += 1
            next
          end
          FileUtils.rm_rf(dir.to_s)
        end

        fu.destroy!
        puts "  removed fu_id=#{fu.id} #{stale_partial_bytes_to_human(c[:bytes])} #{dir}"
        removed += 1
        removed_bytes += c[:bytes].to_i
      rescue StandardError => e
        failed += 1
        $stderr.puts "  FAILED fu_id=#{c[:fu].id}: #{e.class} #{e.message}"
      end

      puts ''
      puts "[fus:cleanup_stale_partial_uploads] done removed=#{removed} " \
           "removed_bytes=#{removed_bytes} (#{stale_partial_bytes_to_human(removed_bytes)}) failed=#{failed}"
    ensure
      lock.flock(File::LOCK_UN)
    end
  end
end
