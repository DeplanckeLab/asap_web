# frozen_string_literal: true

# Rename SLURM stdout/stderr files from slurm.out / slurm.err to exec.out / exec.err under each project tree.
# Intended as a one-off after SlurmService was aligned to exec.* names.
#
# Production only (set ALLOW_NON_PRODUCTION=1 to run elsewhere).
#
# Environment:
#   DRY_RUN=1              Preview renames and archive steps without writing or uploading.
#   PROJECT_KEY=key        Process a single project.
#   SINCE=2026-03-01       Only projects with created_at on or after this date (in the app time zone).
#   WITH_ARCHIVED=1        For archive_status_id 3 (on S3 only): download via Basic.unarchive, rename, re-archive.
#   SKIP_REARCHIVE=1       After unarchive, rename only; leave files on disk (does not upload back to S3).
#
# Archived projects need WITH_ARCHIVED=1 or they are skipped when no local project directory exists.

namespace :projects do
  desc 'Rename slurm.out/slurm.err to exec.out/exec.err (production; see slurm_log_rename.rake header)'
  task rename_slurm_log_files: :environment do
    unless Rails.env.production?
      unless ENV['ALLOW_NON_PRODUCTION'].to_s == '1'
        puts 'This task is restricted to production. Set ALLOW_NON_PRODUCTION=1 to override.'
        exit 1
      end
    end

    dry_run = ENV['DRY_RUN'].to_s == '1'
    filter_key = ENV['PROJECT_KEY'].presence
    with_archived = ENV['WITH_ARCHIVED'].to_s == '1'
    skip_rearchive = ENV['SKIP_REARCHIVE'].to_s == '1'

    since_date = Date.parse(ENV.fetch('SINCE', '2026-03-01'))
    since_cutoff = since_date.in_time_zone.beginning_of_day

    unless ENV['USER_DATA_DIR'].present?
      puts 'USER_DATA_DIR is not set; aborting.'
      exit 1
    end

    unless defined?(archive_project_to_s3!) && defined?(archive_s3_bucket_config)
      puts 'Archive helpers not loaded; ensure lib/tasks/archive.rake defines archive_project_to_s3!'
      exit 1
    end

    scope = Project.where.not(user_id: nil).where.not(key: [nil, ''])
    scope = scope.where('created_at >= ?', since_cutoff)
    scope = scope.where(key: filter_key) if filter_key

    renamed_total = 0
    conflict_total = 0
    skipped = 0
    errors = []
    unarchived_count = 0
    rearchived_count = 0

    rename_pair = lambda do |root_path|
      renamed = 0
      conflicts = 0
      { 'slurm.out' => 'exec.out', 'slurm.err' => 'exec.err' }.each do |old_base, new_base|
        pattern = File.join(root_path.to_s, '**', old_base)
        Dir.glob(pattern).each do |path|
          next unless File.file?(path)

          dest = File.join(File.dirname(path), new_base)
          if File.exist?(dest)
            conflicts += 1
            puts "[conflict] #{path}: #{new_base} already exists"
            next
          end

          if dry_run
            puts "[dry-run] mv #{path} -> #{dest}"
          else
            File.rename(path, dest)
            puts "[rename] #{path} -> #{dest}"
          end
          renamed += 1
        end
      end
      [renamed, conflicts]
    end

    scope.find_each do |project|
      project.reload
      root = Pathname.new(ENV.fetch('USER_DATA_DIR')) + project.user_id.to_s + project.key
      was_archived = project.archived_on_s3?
      unarchived_for_task = false

      if project.archive_status_id == 2
        skipped += 1
        puts "[skip] #{project.key}: archive_status_id=2 (archive in progress)"
        next
      end

      if project.archive_status_id == 4
        skipped += 1
        puts "[skip] #{project.key}: archive_status_id=4 (unarchive in progress)"
        next
      end

      unless root.directory?
        if was_archived
          unless with_archived
            skipped += 1
            puts "[skip] #{project.key}: archived on S3, no local dir (WITH_ARCHIVED=1 to unarchive, rename, re-archive)"
            next
          end
          if dry_run
            puts "[dry-run] #{project.key}: would unarchive, rename slurm logs if present, re-archive"
            next
          end
          puts "[unarchive] #{project.key}"
          unless Basic.unarchive(project.key)
            errors << { key: project.key, error: 'Basic.unarchive failed' }
            puts "[error] #{project.key}: Basic.unarchive failed"
            next
          end
          unarchived_for_task = true
          unarchived_count += 1
          project.reload
        else
          skipped += 1
          puts "[skip] #{project.key}: no directory at #{root}"
          next
        end
      end

      unless root.directory?
        errors << { key: project.key, error: 'project dir missing after unarchive' }
        puts "[error] #{project.key}: directory still missing at #{root}"
        next
      end

      r, c = rename_pair.call(root)
      renamed_total += r
      conflict_total += c

      if unarchived_for_task && was_archived && !dry_run && !skip_rearchive
        if project.sandbox?
          puts "[warn] #{project.key}: sandbox; not re-archiving (data left on disk)"
        else
          suffix = (r.zero? && c.zero?) ? ' (no slurm.out/slurm.err found; restore archive state)' : ''
          puts "[re-archive] #{project.key}#{suffix}"
          s3b = archive_s3_bucket_config
          result = archive_project_to_s3!(project.reload, s3b: s3b, dry_run: false)
          if result == :archived
            rearchived_count += 1
          else
            errors << { key: project.key, error: "re-archive returned #{result.inspect}" }
            puts "[error] #{project.key}: re-archive returned #{result.inspect}"
          end
        end
      end
    rescue StandardError => e
      errors << { key: project.key, error: "#{e.class}: #{e.message}" }
      puts "[error] #{project.key}: #{e.class} - #{e.message}"
    end

    puts ''
    puts dry_run ? 'Dry run complete.' : 'Done.'
    puts "Since: #{since_cutoff.utc.iso8601} (SINCE=#{since_date})"
    puts "Files renamed: #{renamed_total}, conflicts: #{conflict_total}, skipped projects: #{skipped}, " \
         "unarchived: #{unarchived_count}, re-archived: #{rearchived_count}, errors: #{errors.size}"
    exit 1 if errors.any?
  end
end
