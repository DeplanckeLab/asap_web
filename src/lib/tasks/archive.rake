require 'shellwords'
require 'fileutils'
require 'digest'
require 'tempfile'
require 'find'

def include_project_fus_for_archive(project, project_dir)
  upload_data_dir = Pathname.new(ENV.fetch('UPLOAD_DATA_DIR'))
  project_fus_dir = project_dir + 'fus'
  FileUtils.mkdir_p(project_fus_dir) unless File.exist?(project_fus_dir)

  input_file = Dir.entries(project_dir).find { |entry| File.symlink?(project_dir + entry) && entry.match(/^input/) }
  destination_file = File.readlink(project_dir + input_file) if input_file

  Fu.where(project_id: project.id).order(id: :desc).each do |fu|
    fu_dir = upload_data_dir + fu.id.to_s
    next unless File.exist?(fu_dir)

    target_fu_dir = project_fus_dir + fu.id.to_s
    unless File.exist?(target_fu_dir)
      FileUtils.cp_r(fu_dir, project_fus_dir)
      Dir.glob(File.join(target_fu_dir, '**', '*')).each do |entry|
        next unless File.exist?(entry) && File.symlink?(entry)

        symlink_target = File.realpath(entry)
        FileUtils.rm(entry)
        FileUtils.cp_r(symlink_target, entry)
      end
    end

    FileUtils.rm_r(fu_dir) if File.exist?(target_fu_dir)
  end

  return unless destination_file.present? && input_file.present?

  Dir.chdir(project_dir) do
    new_destination_file = destination_file.to_s.gsub(/^#{Regexp.escape(upload_data_dir.to_s)}/, './fus')
    if File.exist?(new_destination_file)
      FileUtils.ln_sf(new_destination_file, project_dir + input_file)
    end
  end
end

def archive_s3_bucket_config
  {
    key: '20000-af8a16d143d9920a26869b30700c3da4',
    endpoint: 'https://s3.epfl.ch',
    region: 'us-west-2'
  }
end

def project_archive_due?(project, cutoff_time)
  return true if cutoff_time.nil?
  last_seen_at = project.viewed_at || project.updated_at || project.created_at
  last_seen_at.present? && last_seen_at < cutoff_time
end

def file_md5_hex(filepath)
  Digest::MD5.file(filepath.to_s).hexdigest
end

def s3_object_md5_hex(s3_client, bucket:, key:)
  Tempfile.create(['archive-md5-check', '.tgz']) do |tmpfile|
    tmpfile.close
    project_ref = Struct.new(:key).new(key)
    download_ok = Basic.write_file_from_s3(s3_client, bucket, project_ref, tmpfile.path)
    raise "S3 download failed for MD5 verification key=#{key}" unless download_ok

    Digest::MD5.file(tmpfile.path).hexdigest
  end
end

def directory_latest_mtime(path)
  return nil unless File.exist?(path)

  latest = File.lstat(path).mtime
  Find.find(path.to_s) do |entry|
    mtime = File.lstat(entry).mtime
    latest = mtime if mtime > latest
  rescue StandardError
    next
  end
  latest
end

def retrieve_project_snapshot_from_s3(project, s3_client:, s3_bucket:, tmp_dir:)
  FileUtils.rm_r(tmp_dir) if File.exist?(tmp_dir)
  FileUtils.mkdir_p(tmp_dir)

  archive_path = tmp_dir + "#{project.key}.tgz"
  project_ref = Struct.new(:key).new(project.key)
  downloaded = Basic.write_file_from_s3(s3_client, s3_bucket, project_ref, archive_path.to_s)
  return nil unless downloaded && File.exist?(archive_path) && File.size(archive_path).to_i.positive?

  cmd = "cd #{Shellwords.escape(tmp_dir.to_s)} && pigz -p 8 -dc #{Shellwords.escape(archive_path.to_s)} | tar -xf -"
  `#{cmd}`
  return nil unless $?.success?

  restored_dir = tmp_dir + project.key
  return nil unless File.exist?(restored_dir)

  {
    restored_dir: restored_dir,
    restored_mtime: directory_latest_mtime(restored_dir)
  }
end

def directory_size_bytes(path)
  return 0 unless File.exist?(path)

  total = 0
  Find.find(path.to_s) do |entry|
    next unless File.file?(entry)

    total += File.size(entry).to_i
  rescue StandardError
    next
  end
  total
end

def directory_non_empty?(path)
  return false unless File.directory?(path)

  Dir.children(path.to_s).any?
rescue StandardError
  false
end

def archive_project_to_s3!(project, s3b:, dry_run: false)
  base_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + project.user_id.to_s
  project_dir = base_dir + project.key
  return :missing_local_dir unless File.directory?(project_dir)
  return :empty_local_dir unless directory_non_empty?(project_dir)

  if dry_run
    Rails.logger.info("[archive][dry-run] would archive project=#{project.id} key=#{project.key}")
    return :dry_run
  end

  archive_file = Pathname.new("#{project_dir}.tgz")
  File.delete(archive_file) if File.exist?(archive_file)

  project.update!(archive_status_id: 2)
  include_project_fus_for_archive(project, project_dir)

  cmd = "tar -cf - -C #{Shellwords.escape(base_dir.to_s)} #{Shellwords.escape(project.key)} | pigz -9 -p 32 > #{Shellwords.escape(archive_file.to_s)}"
  `#{cmd}`
  raise "Archive command failed for #{project.key}" unless $?.success?
  raise "Archive file missing for #{project.key}" unless File.exist?(archive_file) && File.size(archive_file).to_i > 0

  local_md5 = file_md5_hex(archive_file)

  s3_obj = Basic.write_file_on_s3(s3b, archive_file.to_s, { key: project.key, md5: local_md5 })
  raise "S3 upload failed for #{project.key}" unless s3_obj

  gzip_test_cmd = "gzip -t #{Shellwords.escape(archive_file.to_s)}"
  `#{gzip_test_cmd} 2>&1`
  gzip_ok = $?.success?

  list_cmd = "gunzip -c #{Shellwords.escape(archive_file.to_s)} | tar -t >/dev/null"
  `#{list_cmd} 2>&1`
  list_ok = $?.success?

  archive_valid = gzip_ok && list_ok
  raise "Archive integrity check failed for #{project.key}" unless archive_valid

  h_s3_settings = Basic.get_s3_settings
  s3_client = Basic.connect_s3(s3b, h_s3_settings)
  local_size = File.size(archive_file).to_i
  remote_head = s3_client.head_object(bucket: s3b[:key], key: project.key)
  remote_size = remote_head.content_length.to_i
  raise "S3 and local archive size mismatch for #{project.key}" unless local_size == remote_size

  remote_md5 = s3_object_md5_hex(s3_client, bucket: s3b[:key], key: project.key)
  raise "S3 and local archive MD5 mismatch for #{project.key}" unless local_md5 == remote_md5

  File.delete(archive_file) if File.exist?(archive_file)
  FileUtils.rm_r(project_dir) if File.exist?(project_dir)
  project.update!(archive_status_id: 3, disk_size_archived: remote_size)
  :archived
rescue StandardError => e
  Rails.logger.error("[archive] project=#{project.id} key=#{project.key} error=#{e.class} #{e.message}")
  project.update(archive_status_id: 1) if project.archive_status_id == 2
  :failed
end

def delete_project_archive_from_s3!(project, s3b:)
  h_s3_settings = Basic.get_s3_settings
  s3 = Basic.connect_s3(s3b, h_s3_settings)
  s3.delete_object(bucket: s3b[:key], key: project.key)
  :deleted
rescue Aws::S3::Errors::ServiceError => e
  Rails.logger.error("[sandbox_cleanup][s3] project=#{project.id} key=#{project.key} error=#{e.class} #{e.message}")
  :failed
end

def delete_sandbox_project!(project, s3b:, dry_run: false)
  user_data_dir = Pathname.new(ENV.fetch('USER_DATA_DIR'))
  project_dir = user_data_dir + project.user_id.to_s + project.key
  archive_file = Pathname.new("#{project_dir}.tgz")

  if dry_run
    puts "[sandbox_cleanup][dry-run] would delete project=#{project.id} key=#{project.key} title=#{project.name.inspect} user_email=#{project.user&.email.inspect} updated_at=#{project.updated_at&.utc&.iso8601.inspect}"
    return :dry_run
  end

  if [2, 4].include?(project.archive_status_id)
    puts "[sandbox_cleanup] skip project=#{project.id} key=#{project.key} archive_status_id=#{project.archive_status_id}"
    return :skipped_in_progress
  end

  if project.archive_status_id == 3 || project.disk_size_archived.present?
    s3_result = delete_project_archive_from_s3!(project, s3b: s3b)
    return :failed unless s3_result == :deleted
  end

  Fu.where(project_id: project.id).update_all(project_id: nil)

  project.destroy!

  FileUtils.rm_r(project_dir) if File.exist?(project_dir)
  File.delete(archive_file) if File.exist?(archive_file)
  :deleted
rescue StandardError => e
  Rails.logger.error("[sandbox_cleanup] project=#{project.id} key=#{project.key} error=#{e.class} #{e.message}")
  :failed
end

desc 'Archive projects to S3 (optionally one key)'
task :archive, [:project_key] => :environment do |_t, args|
  s3b = archive_s3_bucket_config
  idle_days = ENV.fetch('PROJECT_ARCHIVE_IDLE_DAYS', '7').to_i
  cutoff_time = Time.current - idle_days.days

  projects = if args[:project_key].present?
               Project.where(key: args[:project_key]).where(sandbox: false)
             else
               Project.where(archive_status_id: 1).where(public_id: nil, sandbox: false)
             end

  projects.find_each do |project|
    should_archive = args[:project_key].present? || project_archive_due?(project, cutoff_time)
    next unless should_archive

    archive_project_to_s3!(project, s3b: s3b, dry_run: false)
  end
end

desc 'Unarchive one project from S3 by key'
task :unarchive, [:project_key] => :environment do |_t, args|
  key = args[:project_key].to_s
  raise 'project_key is required' if key.blank?

  ok = Basic.unarchive(key)
  raise "Unarchive failed for #{key}" unless ok
end

namespace :projects do
  desc 'Archive inactive projects (nightly cron task)'
  task :archive_inactive, [:days, :project_key] => :environment do |_t, args|
    days = (args[:days] || ENV.fetch('PROJECT_ARCHIVE_IDLE_DAYS', '7')).to_i
    cutoff_time = Time.current - days.days
    project_key = args[:project_key].to_s.strip
    project_key = nil if project_key.empty?
    dry_run = ENV['DRY_RUN'] == '1'
    lock_file = Pathname.new(Rails.root) + 'tmp' + 'archive_inactive.lock'
    FileUtils.mkdir_p(lock_file.dirname) unless File.exist?(lock_file.dirname)

    File.open(lock_file, File::RDWR | File::CREAT, 0o644) do |f|
      unless f.flock(File::LOCK_EX | File::LOCK_NB)
        puts "[archive_inactive] another run is already in progress; exiting"
        next
      end

      puts "[archive_inactive] start days=#{days} cutoff=#{cutoff_time.utc.iso8601} dry_run=#{dry_run} project_key=#{project_key || 'all'}"
      s3b = archive_s3_bucket_config

      scope = if project_key
                Project.where(key: project_key).where(sandbox: false)
              else
                Project.where(archive_status_id: 1).where(public_id: nil, sandbox: false)
              end
      candidates = if project_key
                     scope
                   else
                     scope.where("COALESCE(viewed_at, updated_at, created_at) < ?", cutoff_time)
                   end
      counts = Hash.new(0)

      candidates.find_each do |project|
        result = archive_project_to_s3!(project, s3b: s3b, dry_run: dry_run)
        counts[result] += 1
      end

      puts "[archive_inactive] done archived=#{counts[:archived]} failed=#{counts[:failed]} missing_local_dir=#{counts[:missing_local_dir]} empty_local_dir=#{counts[:empty_local_dir]} dry_run=#{counts[:dry_run]}"
      f.flock(File::LOCK_UN)
    end
  end

  task :archive, [:project_key] => :environment do |_t, args|
    Rake::Task[:archive].invoke(args[:project_key])
  end

  task :unarchive, [:project_key] => :environment do |_t, args|
    Rake::Task[:unarchive].invoke(args[:project_key])
  end

  desc 'Delete inactive sandbox projects (nightly cron task)'
  task :delete_inactive_sandboxes, [:days] => :environment do |_t, args|
    days = (args[:days] || ENV.fetch('SANDBOX_DELETE_IDLE_DAYS', '2')).to_i
    cutoff_time = Time.current - days.days
    dry_run = ENV['DRY_RUN'] == '1'
    lock_file = Pathname.new(Rails.root) + 'tmp' + 'delete_inactive_sandboxes.lock'
    FileUtils.mkdir_p(lock_file.dirname) unless File.exist?(lock_file.dirname)

    File.open(lock_file, File::RDWR | File::CREAT, 0o644) do |f|
      unless f.flock(File::LOCK_EX | File::LOCK_NB)
        puts "[sandbox_cleanup] another run is already in progress; exiting"
        next
      end

      puts "[sandbox_cleanup] start days=#{days} cutoff=#{cutoff_time.utc.iso8601} dry_run=#{dry_run}"
      s3b = archive_s3_bucket_config
      counts = Hash.new(0)

      scope = Project.where(sandbox: true, user_id: 1).includes(:user)
      candidates = scope.where("COALESCE(viewed_at, updated_at, created_at) < ?", cutoff_time)

      candidates.find_each do |project|
        result = delete_sandbox_project!(project, s3b: s3b, dry_run: dry_run)
        counts[result] += 1
      end

      puts "[sandbox_cleanup] done deleted=#{counts[:deleted]} failed=#{counts[:failed]} skipped_in_progress=#{counts[:skipped_in_progress]} dry_run=#{counts[:dry_run]}"
      f.flock(File::LOCK_UN)
    end
  end

  desc 'Rescue stuck archive states: reconcile local vs S3, reset status, and rearchive'
  task :rescue_archive_states, [:project_key] => :environment do |_t, args|
    dry_run = ENV['DRY_RUN'] == '1'
    stale_hours = ENV.fetch('STALE_HOURS', '0').to_i
    rearchive = ENV.fetch('REARCHIVE', '1') == '1'
    rearchive_idle_days = ENV.fetch('REARCHIVE_IDLE_DAYS', '7').to_i
    rearchive_cutoff_time = Time.current - rearchive_idle_days.days
    project_key = args[:project_key].to_s.strip
    project_key = nil if project_key.empty?
    user_data_dir = Pathname.new(ENV.fetch('USER_DATA_DIR'))
    tmp_root = Pathname.new(Rails.root) + 'tmp' + 'archive_rescue'
    FileUtils.mkdir_p(tmp_root) unless File.exist?(tmp_root)

    s3b = archive_s3_bucket_config
    h_s3_settings = Basic.get_s3_settings
    s3_client = Basic.connect_s3(s3b, h_s3_settings)

    scope = Project.where(archive_status_id: [2, 4])
    scope = scope.where(key: project_key) if project_key
    scope = scope.where("updated_at < ?", Time.current - stale_hours.hours) if stale_hours.positive?

    puts "[rescue_archive_states] start dry_run=#{dry_run} rearchive=#{rearchive} rearchive_idle_days=#{rearchive_idle_days} stale_hours=#{stale_hours} project_key=#{project_key || 'all'}"
    puts "[rescue_archive_states] candidates=#{scope.count}"

    counts = Hash.new(0)

    scope.find_each do |project|
      begin
        user_dir = user_data_dir + project.user_id.to_s
        local_dir = user_dir + project.key
        local_exists = File.exist?(local_dir)
        local_mtime = directory_latest_mtime(local_dir)
        local_size_bytes = directory_size_bytes(local_dir)
        last_seen_at = project.viewed_at || project.updated_at || project.created_at
        should_rearchive = rearchive && last_seen_at.present? && last_seen_at < rearchive_cutoff_time
        tmp_dir = tmp_root + "project_#{project.id}_#{project.key}"

        s3_snapshot = retrieve_project_snapshot_from_s3(
          project,
          s3_client: s3_client,
          s3_bucket: s3b[:key],
          tmp_dir: tmp_dir
        )
        s3_exists = s3_snapshot.present?
        s3_mtime = s3_snapshot&.dig(:restored_mtime)
        s3_size_bytes = s3_exists ? directory_size_bytes(s3_snapshot[:restored_dir]) : 0

        if local_exists && s3_exists && local_mtime && s3_mtime
          newest_source =
            if local_mtime > s3_mtime
              :local
            elsif s3_mtime > local_mtime
              :s3
            end

          older_source = (newest_source == :local ? :s3 : (newest_source == :s3 ? :local : nil))
          newest_size = newest_source == :local ? local_size_bytes : (newest_source == :s3 ? s3_size_bytes : nil)
          older_size = older_source == :local ? local_size_bytes : (older_source == :s3 ? s3_size_bytes : nil)

          if newest_source && older_source && newest_size && older_size && newest_size < older_size
            puts "[rescue_archive_states][WARNING] ----------------------------------------------------------------"
            puts "[rescue_archive_states][WARNING] NEWER COPY IS SMALLER FOR key=#{project.key}; NO AUTOMATIC ACTION"
            puts "[rescue_archive_states][WARNING] local_mtime=#{local_mtime.utc.iso8601} local_size_bytes=#{local_size_bytes}"
            puts "[rescue_archive_states][WARNING] s3_mtime=#{s3_mtime.utc.iso8601} s3_size_bytes=#{s3_size_bytes}"
            puts "[rescue_archive_states][WARNING] review manually before any repair/archive decision"
            puts "[rescue_archive_states][WARNING] ----------------------------------------------------------------"
            counts[:manual_review_newer_smaller] += 1
            FileUtils.rm_r(tmp_dir) if File.exist?(tmp_dir)
            next
          end
        end

        decision = if !local_exists && s3_exists
                     :s3_only_mark_archived
                   elsif local_exists && !s3_exists
                     :local_only_mark_unarchived
                   elsif local_exists && s3_exists && s3_mtime && local_mtime && s3_mtime > local_mtime
                     :replace_with_s3
                   elsif local_exists
                     :keep_local
                   else
                     :missing_both
                   end

        puts "[rescue_archive_states] project=#{project.id} key=#{project.key} status=#{project.archive_status_id} local_exists=#{local_exists} local_mtime=#{local_mtime&.utc&.iso8601} local_size_bytes=#{local_size_bytes} s3_exists=#{s3_exists} s3_mtime=#{s3_mtime&.utc&.iso8601} s3_size_bytes=#{s3_size_bytes} decision=#{decision}"

        if decision == :missing_both
          counts[:missing_both] += 1
          FileUtils.rm_r(tmp_dir) if File.exist?(tmp_dir)
          next
        end

        if decision == :s3_only_mark_archived
          if dry_run
            puts "[rescue_archive_states][dry-run] would set archive_status_id=3 for key=#{project.key} (S3 exists, local missing)"
          else
            project.update!(archive_status_id: 3)
          end
          counts[:marked_archived_s3_only] += 1
          FileUtils.rm_r(tmp_dir) if File.exist?(tmp_dir)
          next
        end

        if decision == :local_only_mark_unarchived
          if dry_run
            puts "[rescue_archive_states][dry-run] would set archive_status_id=1 and disk_size_archived=nil for key=#{project.key} (local exists, S3 missing)"
          else
            project.update!(archive_status_id: 1, disk_size_archived: nil)
          end
          counts[:marked_unarchived_local_only] += 1
          FileUtils.rm_r(tmp_dir) if File.exist?(tmp_dir)
          next
        end

        if decision == :replace_with_s3
          if dry_run
            puts "[rescue_archive_states][dry-run] would replace local directory with S3 snapshot for key=#{project.key}"
          else
            FileUtils.mkdir_p(user_dir) unless File.exist?(user_dir)
            FileUtils.rm_r(local_dir) if File.exist?(local_dir)
            FileUtils.mv(s3_snapshot[:restored_dir], local_dir)
            puts "[rescue_archive_states] replaced local directory from S3 for key=#{project.key}"
          end
          counts[:replaced_with_s3] += 1
        else
          counts[:kept_local] += 1
        end

        if dry_run
          puts "[rescue_archive_states][dry-run] would set archive_status_id=1 and disk_size_archived=nil for key=#{project.key}"
        else
          project.update!(archive_status_id: 1, disk_size_archived: nil)
        end
        counts[:status_reset] += 1

        if should_rearchive
          if dry_run
            puts "[rescue_archive_states][dry-run] would rearchive key=#{project.key}"
            counts[:rearchive_dry_run] += 1
          else
            rearchive_result = archive_project_to_s3!(project, s3b: s3b, dry_run: false)
            counts[:"rearchive_#{rearchive_result}"] += 1
            puts "[rescue_archive_states] rearchive result key=#{project.key} result=#{rearchive_result}"
          end
        elsif rearchive
          counts[:rearchive_not_due] += 1
          puts "[rescue_archive_states] skip rearchive key=#{project.key} last_seen_at=#{last_seen_at&.utc&.iso8601} cutoff=#{rearchive_cutoff_time.utc.iso8601}"
        else
          counts[:rearchive_skipped] += 1
        end

        FileUtils.rm_r(tmp_dir) if File.exist?(tmp_dir)
      rescue StandardError => e
        counts[:failed] += 1
        Rails.logger.error("[rescue_archive_states] project=#{project.id} key=#{project.key} error=#{e.class} #{e.message}")
      end
    end

    puts "[rescue_archive_states] done manual_review_newer_smaller=#{counts[:manual_review_newer_smaller]} marked_archived_s3_only=#{counts[:marked_archived_s3_only]} marked_unarchived_local_only=#{counts[:marked_unarchived_local_only]} replaced_with_s3=#{counts[:replaced_with_s3]} kept_local=#{counts[:kept_local]} missing_both=#{counts[:missing_both]} status_reset=#{counts[:status_reset]} rearchive_archived=#{counts[:rearchive_archived]} rearchive_failed=#{counts[:rearchive_failed]} rearchive_missing_local_dir=#{counts[:rearchive_missing_local_dir]} rearchive_empty_local_dir=#{counts[:rearchive_empty_local_dir]} rearchive_dry_run=#{counts[:rearchive_dry_run]} rearchive_not_due=#{counts[:rearchive_not_due]} rearchive_skipped=#{counts[:rearchive_skipped]} failed=#{counts[:failed]}"
  end
end
