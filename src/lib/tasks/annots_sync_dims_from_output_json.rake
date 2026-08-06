# frozen_string_literal: true

namespace :annots do
  desc <<~DESC.gsub(/\n/, ' ').strip
    Detect/repair vector metadata annots whose nber_rows x nber_cols equal the loom /matrix
    shape (DB-only; no output.json required). Infers CELL=>1xn, GENE=>nx1, GLOBAL=>1x1.
    Default is dry-run. Set APPLY=1 to write. Optional: RUN_ID=123 PROJECT_ID=456 LIMIT=50
  DESC
  task repair_matrix_shaped_vector_dims: :environment do
    apply = ENV['APPLY'].to_s.strip == '1'
    dry_run = !apply
    run_id = ENV['RUN_ID'].presence&.to_i
    project_id = ENV['PROJECT_ID'].presence&.to_i
    limit = ENV['LIMIT'].presence&.to_i

    plan = Basic.plan_matrix_shaped_vector_annot_repairs(
      project_id: project_id,
      run_id: run_id
    )
    changes = plan[:changes]
    changes = changes.first(limit) if limit && limit.positive?

    by_run = changes.group_by { |c| [c[:annot].run_id, c[:annot].project_id] }

    puts "annots:repair_matrix_shaped_vector_dims dry_run=#{dry_run} apply=#{apply} " \
         "run_id=#{run_id.inspect} project_id=#{project_id.inspect} " \
         "annots=#{changes.size} runs=#{by_run.size}"
    puts 'No DB writes will be made.' if dry_run
    puts 'APPLY=1 set: changes will be written.' if apply

    by_run.each do |(rid, pid), run_changes|
      project = Project.find_by(id: pid)
      step_name = Run.find_by(id: rid)&.step&.name
      puts "Run##{rid} project##{pid} key=#{project&.key} step=#{step_name} " \
           "changes=#{run_changes.size}"
      run_changes.each do |c|
        puts "  #{c[:name]} dim=#{c[:annot].dim}: " \
             "#{c[:from_rows]}x#{c[:from_cols]} -> #{c[:to_rows]}x#{c[:to_cols]}"
      end
    end

    unless dry_run
      changes.each do |change|
        change[:annot].update!(
          nber_rows: change[:to_rows],
          nber_cols: change[:to_cols]
        )
      end
    end

    puts '---'
    puts "annots_#{dry_run ? 'would_change' : 'changed'}=#{changes.size} " \
         "runs_#{dry_run ? 'would_change' : 'changed'}=#{by_run.size}"
    if dry_run && changes.any?
      puts 'Re-run with APPLY=1 to write these changes.'
    end
  end

  desc <<~DESC.gsub(/\n/, ' ').strip
    Reconcile annot dims from output.json metadata (needs files on disk).
    Default: dry-run, vector-corruption filter only. APPLY=1 to write.
    ALL_MISMATCHES=1 includes every dim diff. Optional: RUN_ID= PROJECT_ID=
  DESC
  task sync_dims_from_output_json: :environment do
    apply = ENV['APPLY'].to_s.strip == '1'
    dry_run = !apply
    all_mismatches = ENV['ALL_MISMATCHES'].to_s.strip == '1'
    run_id = ENV['RUN_ID'].presence&.to_i
    project_id = ENV['PROJECT_ID'].presence&.to_i

    scope = Run.where(status_id: 3)
    scope = scope.where(id: run_id) if run_id
    scope = scope.where(project_id: project_id) if project_id

    unless run_id || all_mismatches
      suspicious_sql = <<~SQL
        SELECT DISTINCT run_id
        FROM annots
        WHERE run_id IS NOT NULL
          AND dim != 3
          AND nber_rows > 1
          AND nber_cols > 1
          AND (
            name LIKE '/col_attrs/%'
            OR name LIKE '/row_attrs/%'
            OR name LIKE '/attrs/%'
          )
      SQL
      suspicious_ids = ActiveRecord::Base.connection.select_values(suspicious_sql).map(&:to_i)
      scope = scope.where(id: suspicious_ids)
      puts "Restricted to #{suspicious_ids.size} runs with 2D-looking attr annots " \
           '(set ALL_MISMATCHES=1 to scan all successful runs).'
    end

    logger = Logger.new($stdout)
    logger.level = Logger::INFO

    puts "annots:sync_dims_from_output_json dry_run=#{dry_run} apply=#{apply} " \
         "all_mismatches=#{all_mismatches} run_id=#{run_id.inspect} " \
         "project_id=#{project_id.inspect} runs_in_scope=#{scope.count}"
    puts 'No DB writes will be made.' if dry_run
    puts 'APPLY=1 set: changes will be written.' if apply

    runs_with_plan = 0
    annots_to_change = 0
    runs_changed = 0
    runs_no_json = 0
    runs_ok = 0
    skipped_non_corruption = 0

    scope.find_each do |run|
      plan = Basic.plan_sync_run_annots_from_output_json(run)
      if plan.nil?
        runs_no_json += 1
        next
      end

      changes = plan[:changes]
      unless all_mismatches
        before = changes.size
        changes = changes.select do |c|
          c[:from_rows] > 1 && c[:from_cols] > 1 && (c[:to_rows] == 1 || c[:to_cols] == 1)
        end
        skipped_non_corruption += (before - changes.size)
      end

      if changes.empty?
        runs_ok += 1
        next
      end

      runs_with_plan += 1
      annots_to_change += changes.size
      project = run.project
      puts "Run##{run.id} project##{run.project_id} key=#{project&.key} step=#{run.step&.name} " \
           "changes=#{changes.size}"
      changes.each do |c|
        puts "  #{c[:name]}: #{c[:from_rows]}x#{c[:from_cols]} -> #{c[:to_rows]}x#{c[:to_cols]}"
      end

      prefix = dry_run ? '[DRY-RUN] ' : ''
      changes.each do |change|
        logger.info(
          "#{prefix}[annots:sync_dims_from_output_json] Run##{run.id} #{change[:name]}: " \
          "#{change[:from_rows]}x#{change[:from_cols]} -> #{change[:to_rows]}x#{change[:to_cols]}"
        )
        next if dry_run

        change[:annot].update!(
          nber_rows: change[:to_rows],
          nber_cols: change[:to_cols]
        )
      end
      runs_changed += 1
    end

    puts '---'
    puts "runs_ok=#{runs_ok} runs_no_usable_output_json=#{runs_no_json} " \
         "skipped_non_vector_corruption_annots=#{skipped_non_corruption} " \
         "runs_with_mismatches=#{runs_with_plan} annots_mismatched=#{annots_to_change} " \
         "runs_#{dry_run ? 'would_change' : 'changed'}=#{runs_changed}"
    if dry_run && runs_with_plan.positive?
      puts 'Re-run with APPLY=1 to write these changes.'
    end
  end
end
