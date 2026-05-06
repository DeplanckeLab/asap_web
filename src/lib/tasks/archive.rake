require 'shellwords'
require 'fileutils'
require 'digest'
require 'tempfile'
require 'find'

def guided_tour_demo_project_id_for_archive
  return @guided_tour_demo_project_id_for_archive if instance_variable_defined?(:@guided_tour_demo_project_id_for_archive)

  @guided_tour_demo_project_id_for_archive = Project.guided_tour_demo_project&.id
end

def include_project_fus_for_archive(project, project_dir)
  upload_data_dir = Pathname.new(Fu.global_upload_root)
  project_fus_dir = project_dir + 'fus'
  FileUtils.mkdir_p(project_fus_dir) unless File.exist?(project_fus_dir)

  input_file = Dir.entries(project_dir).find { |entry| File.symlink?(project_dir + entry) && entry.match(/^input/) }
  destination_file = File.readlink(project_dir + input_file) if input_file

  Fu.where(project_id: project.id).order(id: :desc).each do |fu|
    fu_dir = fu.upload_dir
    next unless File.exist?(fu_dir.to_s)

    target_fu_dir = project_fus_dir + fu.id.to_s
    if fu_dir.to_s != target_fu_dir.to_s
      unless File.exist?(target_fu_dir)
        FileUtils.cp_r(fu_dir, project_fus_dir)
        Dir.glob(File.join(target_fu_dir.to_s, '**', '*')).each do |entry|
          next unless File.exist?(entry) && File.symlink?(entry)

          symlink_target = File.realpath(entry)
          FileUtils.rm(entry)
          FileUtils.cp_r(symlink_target, entry)
        end
      end
    end

    global_fu_dir = upload_data_dir + fu.id.to_s
    if File.exist?(global_fu_dir.to_s) && File.exist?(target_fu_dir.to_s)
      FileUtils.rm_r(global_fu_dir)
    end
  end

  return unless destination_file.present? && input_file.present?

  Dir.chdir(project_dir) do
    new_destination_file = destination_file.to_s
    new_destination_file = new_destination_file.sub(/^#{Regexp.escape(upload_data_dir.to_s)}/, './fus')
    project_fus_abs = (project_dir + 'fus').to_s
    new_destination_file = new_destination_file.sub(/^#{Regexp.escape(project_fus_abs)}/, './fus')
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

def upload_project_archive_from_snapshot!(project, restored_project_dir:, s3b:)
  archive_file = restored_project_dir.dirname + "#{project.key}.tgz"
  File.delete(archive_file) if File.exist?(archive_file)

  cmd = "tar -cf - -C #{Shellwords.escape(restored_project_dir.dirname.to_s)} #{Shellwords.escape(project.key)} | pigz -9 -p 16 > #{Shellwords.escape(archive_file.to_s)}"
  `#{cmd}`
  raise "Archive rebuild command failed for #{project.key}" unless $?.success?
  raise "Archive rebuild missing for #{project.key}" unless File.exist?(archive_file) && File.size(archive_file).to_i.positive?

  local_md5 = file_md5_hex(archive_file)
  s3_obj = Basic.write_file_on_s3(s3b, archive_file.to_s, { key: project.key, md5: local_md5 })
  raise "S3 upload failed for rebuilt archive #{project.key}" unless s3_obj

  h_s3_settings = Basic.get_s3_settings
  verify_client = Basic.connect_s3(s3b, h_s3_settings)
  local_size = File.size(archive_file).to_i
  remote_head = verify_client.head_object(bucket: s3b[:key], key: project.key)
  remote_size = remote_head.content_length.to_i
  raise "S3 and rebuilt archive size mismatch for #{project.key}" unless local_size == remote_size

  remote_md5 = s3_object_md5_hex(verify_client, bucket: s3b[:key], key: project.key)
  raise "S3 and rebuilt archive MD5 mismatch for #{project.key}" unless local_md5 == remote_md5

  { remote_size: remote_size, local_md5: local_md5 }
ensure
  File.delete(archive_file) if archive_file.present? && File.exist?(archive_file)
end

def archived_project_fus_verification(project, s3_client:, s3_bucket:, s3b:, tmp_root:, delete_verified: false, dry_run: false, repair_archive: false)
  upload_root = Pathname.new(Fu.global_upload_root)
  fu_ids = Fu.where(project_id: project.id).pluck(:id)
  existing_fu_ids = fu_ids.select { |fu_id| File.directory?(upload_root + fu_id.to_s) }
  missing_global = fu_ids.size - existing_fu_ids.size

  if existing_fu_ids.empty?
    return {
      status: :no_global_fus,
      checked: fu_ids.size,
      verified: 0,
      missing_in_archive: 0,
      missing_global: missing_global,
      repaired: 0,
      would_delete: 0,
      deleted: 0
    }
  end

  tmp_dir = tmp_root + "verify_fus_project_#{project.id}_#{project.key}"
  snapshot = retrieve_project_snapshot_from_s3(
    project,
    s3_client: s3_client,
    s3_bucket: s3_bucket,
    tmp_dir: tmp_dir
  )
  return { status: :archive_missing, checked: fu_ids.size, verified: 0, missing_in_archive: existing_fu_ids.size, missing_global: missing_global, repaired: 0, would_delete: 0, deleted: 0 } if snapshot.nil?

  project_fus_root = snapshot[:restored_dir] + 'fus'
  FileUtils.mkdir_p(project_fus_root) unless File.exist?(project_fus_root)
  checked = fu_ids.size
  verified = 0
  missing_in_archive = 0
  repaired = 0
  would_delete = 0
  deleted = 0
  missing_fu_ids = []

  existing_fu_ids.each do |fu_id|
    global_fu_dir = upload_root + fu_id.to_s
    archived_fu_dir = project_fus_root + fu_id.to_s

    unless File.directory?(archived_fu_dir)
      missing_in_archive += 1
      missing_fu_ids << fu_id
      next
    end

    verified += 1
    next unless delete_verified

    if dry_run
      would_delete += 1
    else
      FileUtils.rm_r(global_fu_dir)
      deleted += 1
    end
  rescue StandardError => e
    puts "[verify_archived_fus] project=#{project.id} key=#{project.key} fu_id=#{fu_id} error=#{e.class} #{e.message}"
  end

  if repair_archive && missing_fu_ids.any?
    if dry_run
      repaired = missing_fu_ids.size
    else
      missing_fu_ids.each do |fu_id|
        src = upload_root + fu_id.to_s
        dst = project_fus_root + fu_id.to_s
        FileUtils.cp_r(src, dst)
      end
      upload_project_archive_from_snapshot!(project, restored_project_dir: snapshot[:restored_dir], s3b: s3b)
      repaired = missing_fu_ids.size
      verified += missing_fu_ids.size
      missing_in_archive = 0
    end
  end

  {
    status: :ok,
    checked: checked,
    verified: verified,
    missing_in_archive: missing_in_archive,
    missing_global: missing_global,
    repaired: repaired,
    would_delete: would_delete,
    deleted: deleted
  }
ensure
  FileUtils.rm_r(tmp_dir) if tmp_dir.present? && File.exist?(tmp_dir)
end

def archive_project_to_s3!(project, s3b:, dry_run: false)
  demo_id = guided_tour_demo_project_id_for_archive
  if demo_id.present? && project.id == demo_id
    Rails.logger.info("[archive] skip guided-tour demo project id=#{project.id} key=#{project.key} public_id=#{project.public_id.inspect}")
    return :exempt
  end

  base_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + project.user_id.to_s
  project_dir = base_dir + project.key
  return :missing_local_dir unless File.directory?(project_dir)
  return :empty_local_dir unless directory_non_empty?(project_dir)

  if dry_run
    Rails.logger.info("[archive][dry-run] would archive project=#{project.id} key=#{project.key}")
    return :dry_run
  end

  if Rails.env.development?
    Rails.logger.info("[archive] development: skip S3 upload and local archive for project=#{project.id} key=#{project.key}")
    return :development_skipped
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

def delete_rows_referencing_project_id!(project_id)
  conn = ActiveRecord::Base.connection
  tables = conn.tables - ['projects', 'schema_migrations', 'ar_internal_metadata']
  tables_with_project_id = tables.select { |table| conn.columns(table).map(&:name).include?('project_id') }
  run_ids = conn.select_values("SELECT id FROM runs WHERE project_id = #{project_id.to_i}").map(&:to_i)
  req_ids = conn.select_values("SELECT id FROM reqs WHERE project_id = #{project_id.to_i}").map(&:to_i)
  annot_ids = conn.select_values("SELECT id FROM annots WHERE project_id = #{project_id.to_i}").map(&:to_i)

  unless run_ids.empty?
    tables.each do |table|
      next if table == 'runs'
      next unless conn.columns(table).map(&:name).include?('run_id')

      quoted_table = conn.quote_table_name(table)
      conn.execute("DELETE FROM #{quoted_table} WHERE run_id IN (#{run_ids.join(',')})")
    end
  end

  unless req_ids.empty?
    tables.each do |table|
      next if table == 'reqs'
      next unless conn.columns(table).map(&:name).include?('req_id')

      quoted_table = conn.quote_table_name(table)
      conn.execute("DELETE FROM #{quoted_table} WHERE req_id IN (#{req_ids.join(',')})")
    end
  end

  unless annot_ids.empty?
    tables.each do |table|
      next if table == 'annots'
      next unless conn.columns(table).map(&:name).include?('annot_id')

      quoted_table = conn.quote_table_name(table)
      conn.execute("DELETE FROM #{quoted_table} WHERE annot_id IN (#{annot_ids.join(',')})")
    end
  end

  # Known dependency order for ASAP schema (children before parents).
  ordered_tables = %w[
    annot_cell_sets
    annots
    runs
    reqs
    project_view_logs
  ]
  ordered_tables.each do |table|
    next unless tables_with_project_id.include?(table)
    quoted_table = conn.quote_table_name(table)
    conn.execute("DELETE FROM #{quoted_table} WHERE project_id = #{project_id.to_i}")
    tables_with_project_id.delete(table)
  end

  # Best-effort pass for remaining project_id references.
  3.times do
    progress = false
    tables_with_project_id.dup.each do |table|
      quoted_table = conn.quote_table_name(table)
      begin
        conn.execute("DELETE FROM #{quoted_table} WHERE project_id = #{project_id.to_i}")
        tables_with_project_id.delete(table)
        progress = true
      rescue ActiveRecord::InvalidForeignKey
        next
      end
    end
    break if tables_with_project_id.empty? || !progress
  end

  return if tables_with_project_id.empty?

  raise "Unresolved project_id references for project_id=#{project_id}: #{tables_with_project_id.join(', ')}"
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
  delete_rows_referencing_project_id!(project.id)
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
  idle_days = ENV.fetch('PROJECT_ARCHIVE_IDLE_DAYS', '1').to_i
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
  desc 'Verify FU directories are inside archived project S3 tarballs; optionally delete verified global FU dirs'
  task :verify_archived_fus, [:project_key] => :environment do |_t, args|
    project_key = args[:project_key].to_s.strip
    project_key = nil if project_key.empty?
    delete_verified = ENV['DELETE_VERIFIED'] == '1'
    dry_run = ENV['DRY_RUN'] == '1'
    repair_archive = ENV['REPAIR_ARCHIVE'] == '1'
    lock_file = Pathname.new(Rails.root) + 'tmp' + 'verify_archived_fus.lock'
    tmp_root = Pathname.new(Rails.root) + 'tmp' + 'verify_archived_fus'
    FileUtils.mkdir_p(lock_file.dirname) unless File.exist?(lock_file.dirname)
    FileUtils.mkdir_p(tmp_root) unless File.exist?(tmp_root)

    s3b = archive_s3_bucket_config
    h_s3_settings = Basic.get_s3_settings
    s3_client = Basic.connect_s3(s3b, h_s3_settings)

    scope = Project.where(sandbox: false, archive_status_id: 3)
    scope = scope.where(key: project_key) if project_key

    puts "[verify_archived_fus] start project_key=#{project_key || 'all'} delete_verified=#{delete_verified} dry_run=#{dry_run} repair_archive=#{repair_archive}"
    puts "[verify_archived_fus] archived_projects_in_scope=#{scope.count}"

    counts = Hash.new(0)

    File.open(lock_file, File::RDWR | File::CREAT, 0o644) do |f|
      unless f.flock(File::LOCK_EX | File::LOCK_NB)
        puts '[verify_archived_fus] another run is already in progress; exiting'
        next
      end

      scope.find_each do |project|
        fu_ids = Fu.where(project_id: project.id).pluck(:id)
        next if fu_ids.empty?
        upload_root = Pathname.new(Fu.global_upload_root)
        existing_fu_count = fu_ids.count { |fu_id| File.directory?(upload_root + fu_id.to_s) }
        next if existing_fu_count.zero?

        result = archived_project_fus_verification(
          project,
          s3_client: s3_client,
          s3_bucket: s3b[:key],
          s3b: s3b,
          tmp_root: tmp_root,
          delete_verified: delete_verified,
          dry_run: dry_run,
          repair_archive: repair_archive
        )

        counts[:projects_with_fu] += 1
        counts[:"status_#{result[:status]}"] += 1
        counts[:checked] += result[:checked]
        counts[:verified] += result[:verified]
        counts[:missing_in_archive] += result[:missing_in_archive]
        counts[:missing_global] += result[:missing_global]
        counts[:repaired] += result[:repaired]
        counts[:would_delete] += result[:would_delete]
        counts[:deleted] += result[:deleted]

        puts "[verify_archived_fus] project=#{project.id} key=#{project.key} fu_count=#{fu_ids.size} existing_global_fu_count=#{existing_fu_count} status=#{result[:status]} checked=#{result[:checked]} verified=#{result[:verified]} missing_in_archive=#{result[:missing_in_archive]} missing_global=#{result[:missing_global]} repaired=#{result[:repaired]} would_delete=#{result[:would_delete]} deleted=#{result[:deleted]}"
      rescue StandardError => e
        counts[:failed_projects] += 1
        puts "[verify_archived_fus] project=#{project.id} key=#{project.key} failed error=#{e.class} #{e.message}"
      end

      puts "[verify_archived_fus] done projects_with_fu=#{counts[:projects_with_fu]} status_ok=#{counts[:status_ok]} status_archive_missing=#{counts[:status_archive_missing]} checked=#{counts[:checked]} verified=#{counts[:verified]} missing_in_archive=#{counts[:missing_in_archive]} missing_global=#{counts[:missing_global]} repaired=#{counts[:repaired]} would_delete=#{counts[:would_delete]} deleted=#{counts[:deleted]} failed_projects=#{counts[:failed_projects]}"
      f.flock(File::LOCK_UN)
    end
  end

  desc 'Archive inactive projects (nightly cron task)'
  task :archive_inactive, [:days, :project_key] => :environment do |_t, args|
    days = (args[:days] || ENV.fetch('PROJECT_ARCHIVE_IDLE_DAYS', '1')).to_i
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
                Project.where(archive_status_id: 1).where(sandbox: false)
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

      puts "[archive_inactive] done archived=#{counts[:archived]} failed=#{counts[:failed]} missing_local_dir=#{counts[:missing_local_dir]} empty_local_dir=#{counts[:empty_local_dir]} dry_run=#{counts[:dry_run]} exempt=#{counts[:exempt]} development_skipped=#{counts[:development_skipped]}"
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
    days = (args[:days] || ENV.fetch('SANDBOX_DELETE_IDLE_DAYS', '1')).to_i
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
    candidates_count = scope.count
    puts "[rescue_archive_states] candidates=#{candidates_count}"

    if project_key.present? && candidates_count.zero?
      p = Project.find_by(key: project_key)
      if p.nil?
        puts "[rescue_archive_states] diagnostic: no Project row with key=#{project_key}"
      else
        puts "[rescue_archive_states] diagnostic: project id=#{p.id} key=#{p.key} archive_status_id=#{p.archive_status_id} updated_at=#{p.updated_at&.utc&.iso8601}"
        unless [2, 4].include?(p.archive_status_id)
          puts "[rescue_archive_states] diagnostic: not in scope because archive_status_id is not 2 or 4 (only those states are rescued)"
        end
        if stale_hours.positive? && p.updated_at.present? && p.updated_at >= Time.current - stale_hours.hours
          puts "[rescue_archive_states] diagnostic: not in scope because STALE_HOURS=#{stale_hours} excludes rows with updated_at within the last #{stale_hours} hours"
        end
      end
    end

    counts = Hash.new(0)

    scope.find_each do |project|
      begin
        user_dir = user_data_dir + project.user_id.to_s
        local_dir = user_dir + project.key
        # Match Project#filesystem_project_data_present?: a real project tree is a directory. File.exist?
        # would be true for a stray file at this path, which is not a project directory.
        local_exists = File.directory?(local_dir)
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
            puts "[rescue_archive_states] SKIPPED key=#{project.key}: manual_review_newer_smaller (archive_status_id=#{project.archive_status_id} left unchanged)"
            FileUtils.rm_r(tmp_dir) if File.exist?(tmp_dir)
            next
          end
        end

        # Same notion of "present" as Project#filesystem_project_data_present? (dir with more than ~10KB).
        # A tiny or empty directory must not use :local_only_mark_unarchived or the next HTTP request will
        # reconcile to archived and queue_unarchive_if_needed! will set 4 again.
        filesystem_data_present = project.filesystem_project_data_present?
        decision = if !local_exists && s3_exists
                     :s3_only_mark_archived
                   elsif local_exists && !s3_exists && filesystem_data_present
                     :local_only_mark_unarchived
                   elsif local_exists && !s3_exists && !filesystem_data_present
                     :missing_both
                   elsif local_exists && s3_exists && s3_mtime && local_mtime && s3_mtime > local_mtime
                     :replace_with_s3
                   elsif local_exists
                     :keep_local
                   else
                     :missing_both
                   end

        puts "[rescue_archive_states] project=#{project.id} key=#{project.key} status=#{project.archive_status_id} local_exists=#{local_exists} filesystem_data_present=#{filesystem_data_present} local_mtime=#{local_mtime&.utc&.iso8601} local_size_bytes=#{local_size_bytes} s3_exists=#{s3_exists} s3_mtime=#{s3_mtime&.utc&.iso8601} s3_size_bytes=#{s3_size_bytes} decision=#{decision}"

        if decision == :missing_both
          counts[:missing_both] += 1
          missing_detail = if local_exists
                               'local project dir exists but has no usable project data (same rule as Project#filesystem_project_data_present?); S3 snapshot missing or could not be restored'
                             else
                               'no local project dir under USER_DATA_DIR and S3 snapshot missing or could not be restored (see Basic.write_file_from_s3 / retrieve_project_snapshot_from_s3)'
                             end
          puts "[rescue_archive_states] missing_both key=#{project.key}: #{missing_detail}"
          if project.archive_status_id == 4
            if dry_run
              puts "[rescue_archive_states][dry-run] would set archive_status_id=3 for key=#{project.key} to clear stuck being-unarchived (missing both)"
            else
              project.update!(archive_status_id: 3)
              puts "[rescue_archive_states] set archive_status_id=3 for key=#{project.key} (was 4, missing both) so unarchive can be retried after S3/path is fixed"
            end
            counts[:missing_both_reset_from_unarchiving] += 1
          else
            puts "[rescue_archive_states] status unchanged for key=#{project.key} (missing_both, archive_status_id=#{project.archive_status_id})"
          end
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
        msg = "[rescue_archive_states] FAILED project=#{project.id} key=#{project.key} error=#{e.class} #{e.message}"
        Rails.logger.error(msg)
        puts msg
        puts e.backtrace&.first&.to_s
      end
    end

    puts "[rescue_archive_states] done manual_review_newer_smaller=#{counts[:manual_review_newer_smaller]} marked_archived_s3_only=#{counts[:marked_archived_s3_only]} marked_unarchived_local_only=#{counts[:marked_unarchived_local_only]} replaced_with_s3=#{counts[:replaced_with_s3]} kept_local=#{counts[:kept_local]} missing_both=#{counts[:missing_both]} missing_both_reset_from_unarchiving=#{counts[:missing_both_reset_from_unarchiving]} status_reset=#{counts[:status_reset]} rearchive_archived=#{counts[:rearchive_archived]} rearchive_exempt=#{counts[:rearchive_exempt]} rearchive_failed=#{counts[:rearchive_failed]} rearchive_missing_local_dir=#{counts[:rearchive_missing_local_dir]} rearchive_empty_local_dir=#{counts[:rearchive_empty_local_dir]} rearchive_dry_run=#{counts[:rearchive_dry_run]} rearchive_not_due=#{counts[:rearchive_not_due]} rearchive_skipped=#{counts[:rearchive_skipped]} failed=#{counts[:failed]}"
  end
end
