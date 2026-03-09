require 'shellwords'
require 'fileutils'

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

def archive_project_to_s3!(project, s3b:, dry_run: false)
  base_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + project.user_id.to_s
  project_dir = base_dir + project.key
  return :missing_local_dir unless File.exist?(project_dir)

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

  s3_obj = Basic.write_file_on_s3(s3b, archive_file.to_s, { key: project.key })
  raise "S3 upload failed for #{project.key}" unless s3_obj

  gzip_ok = `gzip -v -t #{Shellwords.escape(archive_file.to_s)} 2>&1`.to_s.strip.empty?
  list_res = `gunzip -c #{Shellwords.escape(archive_file.to_s)} | tar -t 2>&1`
  archive_valid = gzip_ok && !(list_res.include?('tar: short read') || list_res.include?('gunzip: unexpected end of file'))
  raise "Archive integrity check failed for #{project.key}" unless archive_valid

  local_size = File.size(archive_file).to_i
  remote_size = s3_obj.content_length.to_i
  raise "S3 and local archive size mismatch for #{project.key}" unless local_size == remote_size

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
  task :archive_inactive, [:days] => :environment do |_t, args|
    days = (args[:days] || ENV.fetch('PROJECT_ARCHIVE_IDLE_DAYS', '7')).to_i
    cutoff_time = Time.current - days.days
    dry_run = ENV['DRY_RUN'] == '1'
    lock_file = Pathname.new(Rails.root) + 'tmp' + 'archive_inactive.lock'
    FileUtils.mkdir_p(lock_file.dirname) unless File.exist?(lock_file.dirname)

    File.open(lock_file, File::RDWR | File::CREAT, 0o644) do |f|
      unless f.flock(File::LOCK_EX | File::LOCK_NB)
        puts "[archive_inactive] another run is already in progress; exiting"
        next
      end

      puts "[archive_inactive] start days=#{days} cutoff=#{cutoff_time.utc.iso8601} dry_run=#{dry_run}"
      s3b = archive_s3_bucket_config

      scope = Project.where(archive_status_id: 1).where(public_id: nil, sandbox: false)
      candidates = scope.where("COALESCE(viewed_at, updated_at, created_at) < ?", cutoff_time)
      counts = Hash.new(0)

      candidates.find_each do |project|
        result = archive_project_to_s3!(project, s3b: s3b, dry_run: dry_run)
        counts[result] += 1
      end

      puts "[archive_inactive] done archived=#{counts[:archived]} failed=#{counts[:failed]} missing_local_dir=#{counts[:missing_local_dir]} dry_run=#{counts[:dry_run]}"
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

      scope = Project.where(sandbox: true).includes(:user)
      candidates = scope.where("COALESCE(viewed_at, updated_at, created_at) < ?", cutoff_time)

      candidates.find_each do |project|
        result = delete_sandbox_project!(project, s3b: s3b, dry_run: dry_run)
        counts[result] += 1
      end

      puts "[sandbox_cleanup] done deleted=#{counts[:deleted]} failed=#{counts[:failed]} skipped_in_progress=#{counts[:skipped_in_progress]} dry_run=#{counts[:dry_run]}"
      f.flock(File::LOCK_UN)
    end
  end
end
