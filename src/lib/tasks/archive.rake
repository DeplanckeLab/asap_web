require 'shellwords'

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

desc 'Archive projects to S3 (optionally one key)'
task :archive, [:project_key] => :environment do |_t, args|
  s3b = {
    key: '20000-af8a16d143d9920a26869b30700c3da4',
    endpoint: 'https://s3.epfl.ch',
    region: 'us-west-2'
  }
  idle_days = ENV.fetch('PROJECT_ARCHIVE_IDLE_DAYS', '7').to_i
  active_time = idle_days.days

  projects = if args[:project_key].present?
               Project.where(key: args[:project_key])
             else
               Project.where(archive_status_id: 1).where(public_id: nil)
             end

  projects.find_each do |project|
    base_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + project.user_id.to_s
    project_dir = base_dir + project.key
    next unless File.exist?(project_dir)

    should_archive = args[:project_key].present? || (project.viewed_at.present? && (Time.current - project.viewed_at > active_time))
    next unless should_archive

    archive_file = Pathname.new("#{project_dir}.tgz")
    File.delete(archive_file) if File.exist?(archive_file)

    begin
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

      raise "S3 and local archive size mismatch for #{project.key}" unless File.size(archive_file).to_i == s3_obj.content_length.to_i

      File.delete(archive_file) if File.exist?(archive_file)
      FileUtils.rm_r(project_dir) if File.exist?(project_dir)
      project.update!(archive_status_id: 3, disk_size_archived: s3_obj.content_length.to_i)
    rescue StandardError => e
      Rails.logger.error("[archive] #{e.message}")
      project.update(archive_status_id: 1) if project.archive_status_id == 2
    end
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
  task :archive, [:project_key] => :environment do |_t, args|
    Rake::Task[:archive].invoke(args[:project_key])
  end

  task :unarchive, [:project_key] => :environment do |_t, args|
    Rake::Task[:unarchive].invoke(args[:project_key])
  end
end
