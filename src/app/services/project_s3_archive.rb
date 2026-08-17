# frozen_string_literal: true

require 'shellwords'
require 'fileutils'
require 'digest'
require 'tempfile'
require 'find'

class ProjectS3Archive
  class << self
    def bucket_config
      {
        key: '20000-af8a16d143d9920a26869b30700c3da4',
        endpoint: 'https://s3.epfl.ch',
        region: 'us-west-2'
      }
    end

    def archive!(project, s3b: bucket_config, dry_run: false)
      demo_id = guided_tour_demo_project_id
      if demo_id.present? && project.id == demo_id
        Rails.logger.info("[archive] skip guided-tour demo project id=#{project.id} key=#{project.key} public_id=#{project.public_id.inspect}")
        return :exempt
      end

      base_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + project.user_id.to_s
      project_dir = base_dir + project.key
      local_ready = File.directory?(project_dir) && directory_non_empty?(project_dir)

      unless local_ready
        if project.archive_status_id == 2 && mark_archived_from_s3_if_present!(project, s3b)
          return :already_on_s3
        end
        return :missing_local_dir unless File.directory?(project_dir)
        return :empty_local_dir
      end

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

      project.update_archive_metadata!(archive_status_id: 2)
      include_project_fus(project, project_dir)

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
      project.update_archive_metadata!(archive_status_id: 3, disk_size_archived: remote_size)
      :archived
    rescue StandardError => e
      Rails.logger.error("[archive] project=#{project.id} key=#{project.key} error=#{e.class} #{e.message}")
      project.update_archive_metadata!(archive_status_id: 1) if project.archive_status_id == 2
      :failed
    end

    def include_project_fus(project, project_dir)
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

    def directory_non_empty?(path)
      return false unless File.directory?(path)

      Dir.children(path.to_s).any?
    rescue StandardError
      false
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

    private

    def guided_tour_demo_project_id
      Project.guided_tour_demo_project&.id
    end

    def mark_archived_from_s3_if_present!(project, s3b)
      h_s3_settings = Basic.get_s3_settings
      s3_client = Basic.connect_s3(s3b, h_s3_settings)
      remote_head = s3_client.head_object(bucket: s3b[:key], key: project.key)
      remote_size = remote_head.content_length.to_i
      return false unless remote_size.positive?

      project.update_archive_metadata!(archive_status_id: 3, disk_size_archived: remote_size)
      Rails.logger.info("[archive] project=#{project.key} local dir missing after interrupted archive; S3 object present size=#{remote_size}, set archive_status_id=3")
      true
    rescue Aws::S3::Errors::NotFound, Aws::S3::Errors::NoSuchKey
      false
    end
  end
end
