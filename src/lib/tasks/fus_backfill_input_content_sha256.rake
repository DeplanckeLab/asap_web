# frozen_string_literal: true

namespace :fus do
  desc 'Backfill projects.input_content_sha256 (and fus.content_sha256) for public projects'
  task backfill_input_content_sha256: :environment do
    scope = Project.where(public: true, being_deleted: false)
                   .where(input_content_sha256: [nil, ''])
    total = scope.count
    puts "Public projects missing input_content_sha256: #{total}"

    done = 0
    skipped = 0
    failed = 0

    scope.find_each do |project|
      begin
        sha = InputFileSha256.ensure_for_project!(project)
        if sha.present?
          done += 1
          puts "OK project_id=#{project.id} key=#{project.key} public_id=#{project.public_id} sha=#{sha}"
        else
          skipped += 1
          puts "SKIP project_id=#{project.id} key=#{project.key} (input file missing)"
        end
      rescue StandardError => e
        failed += 1
        puts "FAIL project_id=#{project.id} key=#{project.key}: #{e.class} - #{e.message}"
      end
    end

    puts "Done. hashed=#{done} skipped=#{skipped} failed=#{failed}"
  end
end
