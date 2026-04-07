# frozen_string_literal: true

namespace :legacy do
  rename_pairs_fn = lambda do |children|
    pairs = []
    children.each do |name|
      next if name.include?("/")

      case name
      when /\Ainput_file(\.|$)/
        next
      when /\Ainput\.(.+)\z/
        pairs << [name, "input_file.#{$1}"]
      when "input"
        pairs << %w[input input_file]
      end
    end
    pairs
  end

  desc <<~DESC.squish
    Rename project root input.<ext> (and bare "input") to input_file.<ext> / input_file.
    Updates projects.input_filename when it still matches the old basename.
    Project path matches Basic.unarchive: USER_DATA_DIR + user_id + key.
    DRY_RUN=1 to preview. PROJECT_KEY=key for one project.
    Archived on S3 (archive_status_id 3): skipped unless WITH_ARCHIVED=1 (unarchive, rename, re-archive via archive_project_to_s3!).
    SKIP_REARCHIVE=1 after unarchive leaves data on disk. Sandbox projects are not re-archived (warn only).
  DESC
  task rename_legacy_input_filenames: :environment do
    dry_run = ENV["DRY_RUN"].to_s == "1"
    filter_key = ENV["PROJECT_KEY"].presence
    with_archived = ENV["WITH_ARCHIVED"].to_s == "1"
    skip_rearchive = ENV["SKIP_REARCHIVE"].to_s == "1"

    unless ENV["USER_DATA_DIR"].present?
      puts "USER_DATA_DIR is not set; aborting."
      exit 1
    end

    unless defined?(archive_project_to_s3!) && defined?(archive_s3_bucket_config)
      puts "Archive helpers not loaded; ensure lib/tasks/archive.rake loads before this task (alphabetical order)."
      exit 1
    end

    scope = Project.where.not(user_id: nil).where.not(key: [nil, ""])
    scope = scope.where(key: filter_key) if filter_key

    renamed_files = 0
    updated_rows = 0
    skipped = 0
    errors = []
    unarchived_count = 0
    rearchived_count = 0

    scope.find_each do |project|
      project.reload
      root = Pathname.new(ENV.fetch("USER_DATA_DIR")) + project.user_id.to_s + project.key
      was_archived = project.archived_on_s3?
      unarchived_for_task = false

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
            puts "[dry-run] #{project.key}: would unarchive, rename if needed, re-archive"
            next
          end
          puts "[unarchive] #{project.key}"
          unless Basic.unarchive(project.key)
            errors << { key: project.key, error: "Basic.unarchive failed" }
            puts "[error] #{project.key}: Basic.unarchive failed"
            next
          end
          unarchived_for_task = true
          unarchived_count += 1
          project.reload
        else
          next
        end
      end

      unless root.directory?
        errors << { key: project.key, error: "project dir missing after unarchive" }
        puts "[error] #{project.key}: directory still missing at #{root}"
        next
      end

      children = Dir.children(root.to_s)
      pairs = rename_pairs_fn.call(children)

      if pairs.empty?
        if unarchived_for_task && was_archived && !dry_run && !skip_rearchive
          if project.sandbox?
            puts "[warn] #{project.key}: sandbox; left on disk after unarchive (no legacy input.* to rename)"
          else
            puts "[re-archive] #{project.key} (no renames; restore archive state)"
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
        next
      end

      pairs.each do |old_name, new_name|
        src = root + old_name
        dest = root + new_name
        unless File.symlink?(src.to_s) || File.file?(src.to_s)
          skipped += 1
          puts "[skip] #{project.key}: #{old_name} is not a file or symlink"
          next
        end
        if File.exist?(dest.to_s) || File.symlink?(dest.to_s)
          skipped += 1
          puts "[skip] #{project.key}: target exists #{new_name}"
          next
        end

        if dry_run
          puts "[dry-run] mv #{src} -> #{dest}"
        else
          FileUtils.mv(src.to_s, dest.to_s)
          puts "[rename] #{project.key}: #{old_name} -> #{new_name}"
        end
        renamed_files += 1

        next if dry_run

        if project.input_filename.to_s == old_name
          project.update_column(:input_filename, new_name)
          updated_rows += 1
          puts "         updated projects.input_filename to #{new_name}"
        end
      end

      if unarchived_for_task && was_archived && !dry_run && !skip_rearchive
        if project.sandbox?
          puts "[warn] #{project.key}: sandbox; not re-archiving (data left on disk)"
        else
          puts "[re-archive] #{project.key}"
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

    puts ""
    puts dry_run ? "Dry run complete." : "Done."
    puts "Renames: #{renamed_files}, DB updates: #{updated_rows}, skipped: #{skipped}, " \
         "unarchived: #{unarchived_count}, re-archived: #{rearchived_count}, errors: #{errors.size}"
    exit 1 if errors.any?
  end
end
