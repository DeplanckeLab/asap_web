desc 'Fix imported flag on annots (parsing-only legacy rule + undo wrongful marks on pipeline steps)'
task fix_annots_imported: :environment do
  parsing_step_ids = Step.where(name: 'parsing').pluck(:id)
  import_metadata_step_ids = Step.where(name: 'import_metadata').pluck(:id)
  allowed_imported_step_ids = (parsing_step_ids + import_metadata_step_ids).uniq

  reset = 0
  if allowed_imported_step_ids.any?
    scope = Annot.joins(:run).where(imported: true).where.not(runs: { step_id: allowed_imported_step_ids })
  else
    scope = Annot.joins(:run).where(imported: true)
  end
  scope.find_each do |annot|
    step_name = annot.run&.step&.name || 'unknown'
    annot.update!(imported: false)
    reset += 1
    puts "annot #{annot.id} #{annot.name} on step #{step_name} run #{annot.run_id} => imported false (pipeline output)"
  end

  updated = 0
  Step.where(name: 'parsing').find_each do |step|
    expected_static = Basic.resolved_expected_output_datasets(step, {})
    next if expected_static.empty?

    Run.where(step_id: step.id).find_each do |run|
      expected = Basic.resolved_expected_output_datasets(step, {})

      Annot.where(project_id: run.project_id, run_id: run.id, imported: false).find_each do |annot|
        name = Basic.normalize_dataset_path(annot.name)
        next if name.empty?
        next if expected.include?(name)

        annot.update!(imported: true)
        updated += 1
        puts "annot #{annot.id} #{annot.name} on step parsing run #{run.id} => imported true"
      end
    end
  end

  puts "Reset #{reset} wrongly imported annot(s); marked #{updated} parsing annot(s) as imported"

  backfilled = 0
  Annot.where(imported: true).where("data_class_ids IS NULL OR data_class_ids = ''").find_each do |annot|
    next unless Basic.backfill_imported_annot_data_classes!(annot)

    backfilled += 1
    puts "annot #{annot.id} #{annot.name} => data_class_ids #{annot.data_class_ids}"
  end
  puts "Backfilled data_class_ids on #{backfilled} imported annot(s)"
end
