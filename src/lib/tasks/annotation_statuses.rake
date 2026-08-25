# frozen_string_literal: true

namespace :annotation_statuses do
  desc 'Backfill annotation_statuses for all AnnotCellSet rows'
  task backfill: :environment do
    started = Time.current
    puts '[annotation_statuses:backfill] starting...'
    AnnotationStatusService.backfill_all!
    puts "[annotation_statuses:backfill] done in #{(Time.current - started).round(1)}s " \
         "(rows=#{AnnotationStatus.count})"
  end

  desc 'Backfill annotation_statuses for one project (project_id=)'
  task backfill_project: :environment do
    project_id = ENV['project_id'].to_i
    abort 'Usage: rake annotation_statuses:backfill_project project_id=123' if project_id <= 0

    project = Project.find_by(id: project_id)
    abort "Project #{project_id} not found" unless project

    started = Time.current
    count = 0
    AnnotCellSet.where(project_id: project.id).find_each do |acs|
      next unless acs.annot

      AnnotationStatusService.refresh!(annot: acs.annot, cat_idx: acs.cat_idx)
      count += 1
    end
    puts "[annotation_statuses:backfill_project] project=#{project_id} " \
         "refreshed=#{count} in #{(Time.current - started).round(1)}s"
  end
end
