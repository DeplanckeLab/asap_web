# frozen_string_literal: true

# Shared resolver for runs:simulate_remap_runs_to_project_catalog_by_name and
# runs:apply_remap_to_project_catalog_by_name (same rules as the simulate task desc).
module RunCatalogRemapByName
  Result = Struct.new(:outcome, :mapped_step_id, :mapped_std_method_id, keyword_init: true)

  module_function

  def resolve(run)
    project = run.project
    return Result.new(outcome: :missing_project) unless project

    version = project.version_for_catalog
    return Result.new(outcome: :skipped_catalog_version_id_lte_3) unless version&.id.to_i > 3

    img = project.asap_docker_image_for_catalog
    return Result.new(outcome: :no_catalog_docker) unless img

    st = run.step
    return Result.new(outcome: :no_step_row) unless st

    step_rows = project.catalog_steps.where(name: st.name).to_a
    return Result.new(outcome: :no_catalog_step) if step_rows.empty?
    return Result.new(outcome: :ambiguous_step) if step_rows.size > 1

    mapped_step_id = step_rows.first.id
    mapped_std_method_id = nil

    if run.std_method_id.present?
      sm = run.std_method || StdMethod.find_by(id: run.std_method_id)
      return Result.new(outcome: :missing_current_std_method_row) unless sm

      std_rows = project.catalog_std_methods(include_obsolete: true).where(step_id: mapped_step_id).where(name: sm.name).to_a
      return Result.new(outcome: :no_catalog_std_method) if std_rows.empty?

      resolved_std =
        if std_rows.size == 1
          std_rows.first
        else
          active = std_rows.reject(&:obsolete)
          active.size == 1 ? active.first : nil
        end

      return Result.new(outcome: :ambiguous_std_method) unless resolved_std

      mapped_std_method_id = resolved_std.id
    end

    if mapped_step_id == run.step_id && mapped_std_method_id == run.std_method_id
      Result.new(outcome: :no_change)
    else
      Result.new(outcome: :remap, mapped_step_id: mapped_step_id, mapped_std_method_id: mapped_std_method_id)
    end
  end
end

namespace :runs do
  desc <<~DESC.squish
    Read-only: for each run, check that the run's Step (and optional StdMethod) match the catalog identity
    (versions.id AND docker_images.id). Uses Project#version_for_catalog and Basic.get_asap_docker on that
    Version (same as pipeline / catalog_steps). step.version_id and step.docker_image_id must match;
    std_method.step_id must match run.step_id when std_method_id is set; std_method.version_id /
    std_method.docker_image_id when present must match the same expected pair.
    When std_method_id is set: std_method.step_id == runs.step_id; if std_method.docker_image_id or
    std_method.version_id is set, they must match the same expected pair.
    Does not modify data. PROJECT_IDS=id,... or RUN_IDS=id,... limits scope. LIMIT=n caps runs scanned.
    VERBOSE=1 prints each mismatch line. SUMMARY_ONLY=1 prints only counts.
  DESC
  task check_step_std_method_version_alignment: :environment do
    project_ids = ENV["PROJECT_IDS"].to_s.split(",").map(&:strip).map(&:to_i).reject(&:zero?)
    run_ids = ENV["RUN_IDS"].to_s.split(",").map(&:strip).map(&:to_i).reject(&:zero?)
    limit = ENV["LIMIT"].to_s.strip.presence&.to_i
    limit = nil if limit && limit <= 0
    verbose = ENV["VERBOSE"] == "1"
    summary_only = ENV["SUMMARY_ONLY"] == "1"

    scope = Run.includes(:project, :step, :std_method)
    scope = scope.where(project_id: project_ids) if project_ids.any?
    scope = scope.where(id: run_ids) if run_ids.any?

    counts = Hash.new(0)
    scanned = 0

    report = lambda do |msg|
      puts msg unless summary_only
    end

    iterate =
      if limit
        ->(&block) { scope.order(:id).limit(limit).each(&block) }
      else
        ->(&block) { scope.find_each(&block) }
      end

    iterate.call do |run|
      scanned += 1
      project = run.project
      unless project
        counts[:missing_project] += 1
        next
      end

      version = project.version_for_catalog
      unless version
        counts[:missing_resolved_version] += 1
        report.call("run_id=#{run.id} project_id=#{run.project_id} key=#{project.key}: no Version (projects.version_id=#{project.version_id.inspect})") if verbose
        next
      end

      expected_version_id = version.id

      img = project.asap_docker_image_for_catalog
      unless img
        counts[:missing_expected_docker_image] += 1
        report.call("run_id=#{run.id} project_id=#{project.id} key=#{project.key}: get_asap_docker nil for version_id=#{expected_version_id}") if verbose
        next
      end

      expected_docker_id = img.id

      step = run.step
      unless step
        counts[:missing_step_row] += 1
        report.call("run_id=#{run.id} step_id=#{run.step_id}: step row missing") if verbose
        next
      end

      ok = true
      reasons = []

      if step.docker_image_id != expected_docker_id
        ok = false
        counts[:mismatch_step_docker_image_id] += 1
        reasons << "step.docker_image_id=#{step.docker_image_id} expected=#{expected_docker_id}"
      end

      if step.version_id != expected_version_id
        ok = false
        counts[:mismatch_step_version_id] += 1
        reasons << "step.version_id=#{step.version_id} expected=#{expected_version_id}"
      end

      if run.std_method_id.present?
        sm = run.std_method
        unless sm
          sm = StdMethod.find_by(id: run.std_method_id)
        end
        unless sm
          ok = false
          counts[:missing_std_method_row] += 1
          reasons << "std_method_id=#{run.std_method_id} row missing"
        else
          if sm.step_id != run.step_id
            ok = false
            counts[:mismatch_std_method_step_id] += 1
            reasons << "std_method.step_id=#{sm.step_id} run.step_id=#{run.step_id}"
          end

          if sm.docker_image_id.present? && sm.docker_image_id != expected_docker_id
            ok = false
            counts[:mismatch_std_method_docker_image_id] += 1
            reasons << "std_method.docker_image_id=#{sm.docker_image_id} expected=#{expected_docker_id}"
          end

          if sm.version_id.present? && sm.version_id != expected_version_id
            ok = false
            counts[:mismatch_std_method_version_id] += 1
            reasons << "std_method.version_id=#{sm.version_id} expected=#{expected_version_id}"
          end
        end
      end

      if ok
        counts[:ok] += 1
      else
        counts[:mismatch_total] += 1
        if verbose
          report.call(
            "run_id=#{run.id} project_id=#{project.id} key=#{project.key} " \
            "projects.version_id=#{project.version_id.inspect} catalog_version_id=#{expected_version_id} " \
            "expected_docker_image_id=#{expected_docker_id} run.step_id=#{run.step_id} " \
            "std_method_id=#{run.std_method_id.inspect} | #{reasons.join(' ; ')}"
          )
        end
      end
    end

    puts "[runs:check_step_std_method_version_alignment] scanned=#{scanned}"
    puts "  #{counts.map { |k, v| "#{k}=#{v}" }.join(' ')}"
    puts "[runs:check_step_std_method_version_alignment] done"
  end

  desc <<~DESC.squish
    Read-only simulation: for each project with runs, infer a candidate projects.version_id as the mode of
    steps.version_id over all runs that have a step (ties: higher version_id wins). Then check whether
    every run's Step and optional StdMethod already match the catalog for that Version (same rules as
    runs:check_step_std_method_version_alignment: step.version_id and step.docker_image_id must equal
    Version id and Basic.get_asap_docker(Version) id; std_method step_id and optional version/docker).
    Nothing is written. PROJECT_IDS=id,... limits projects. VERBOSE=1 prints each project line.
  DESC
  task simulate_version_change_from_runs: :environment do
    project_ids = ENV["PROJECT_IDS"].to_s.split(",").map(&:strip).map(&:to_i).reject(&:zero?)
    verbose = ENV["VERBOSE"] == "1"

    scope = Project.joins(:runs).distinct
    scope = scope.where(id: project_ids) if project_ids.any?

    counts = Hash.new(0)

    scope.find_each do |project|
      counts[:projects_scanned] += 1
      tall = Hash.new(0)
      project.runs.includes(:step).find_each do |r|
        vid = r.step&.version_id
        tall[vid] += 1 if vid.present?
      end

      if tall.empty?
        counts[:no_step_version_tally] += 1
        next
      end

      candidate = tall.max_by { |vid, c| [c, vid.to_i] }&.first
      v = Version.find_by(id: candidate)
      unless v
        counts[:candidate_version_missing] += 1
        next
      end

      img = Basic.get_asap_docker(v)
      unless img
        counts[:candidate_no_asap_docker] += 1
        next
      end

      first_bad = nil
      project.runs.includes(:step, :std_method).find_each do |run|
        st = run.step
        unless st
          first_bad = [:missing_step, run.id]
          break
        end
        unless st.version_id == candidate
          first_bad = [:step_version_id, run.id]
          break
        end
        unless st.docker_image_id == img.id
          first_bad = [:step_docker_image_id, run.id]
          break
        end

        next if run.std_method_id.blank?

        sm = run.std_method || StdMethod.find_by(id: run.std_method_id)
        unless sm
          first_bad = [:missing_std_method, run.id]
          break
        end
        unless sm.step_id == run.step_id
          first_bad = [:std_method_step_id, run.id]
          break
        end
        if sm.version_id.present? && sm.version_id != candidate
          first_bad = [:std_method_version_id, run.id]
          break
        end
        if sm.docker_image_id.present? && sm.docker_image_id != img.id
          first_bad = [:std_method_docker_image_id, run.id]
          break
        end
      end

      if first_bad
        counts[:would_fail] += 1
        counts[:"fail_#{first_bad[0]}"] += 1
        if verbose
          puts "FAIL key=#{project.key} id=#{project.id} projects.version_id=#{project.version_id.inspect} " \
               "candidate=#{candidate} first_bad=#{first_bad[0]} run_id=#{first_bad[1]}"
        end
      else
        counts[:would_agree] += 1
        if verbose
          puts "OK key=#{project.key} id=#{project.id} projects.version_id=#{project.version_id.inspect} candidate=#{candidate}"
        end
      end
    end

    puts "[runs:simulate_version_change_from_runs] projects_scanned=#{counts[:projects_scanned]}"
    puts "  #{counts.map { |k, v| "#{k}=#{v}" }.join(' ')}"
    puts "[runs:simulate_version_change_from_runs] done"
  end

  desc <<~DESC.squish
    Read-only simulation: keep projects.version_id (via Project#version_for_catalog) as the source of truth.
    For each run, match catalog by names in two steps: (1) find a catalog Step with the same steps.name as the
    run's current step (project catalog_steps: same version_id and docker_image_id as the project catalog). (2) If
    run.std_method_id is set, find a catalog StdMethod with the same std_methods.name on that target step only
    (catalog_std_methods with include_obsolete: true so names that only exist on obsolete rows still match). If several
    rows share the std_method name, use the unique non-obsolete row when exactly one exists; otherwise count as
    ambiguous. Count whether
    remapping (step_id, std_method_id) would succeed, would be a no-op, or fail (missing step name, ambiguous
    name match, missing std_method name, etc.). Runs are skipped when Project#version_for_catalog is missing or
    its id is not greater than 3 (legacy versions without docker_images in env_json). Nothing is written.
    PROJECT_IDS=id,... limits projects. RUN_IDS=id,... limits runs. VERBOSE=1 prints each failing run line (can be large).
  DESC
  task simulate_remap_runs_to_project_catalog_by_name: :environment do
    project_ids = ENV["PROJECT_IDS"].to_s.split(",").map(&:strip).map(&:to_i).reject(&:zero?)
    run_ids = ENV["RUN_IDS"].to_s.split(",").map(&:strip).map(&:to_i).reject(&:zero?)
    verbose = ENV["VERBOSE"] == "1"

    counts = Hash.new(0)

    run_scope = Run.includes(:project, :step, :std_method).references(:project)
    run_scope = run_scope.where(project_id: project_ids) if project_ids.any?
    run_scope = run_scope.where(id: run_ids) if run_ids.any?

    run_scope.find_each do |run|
      counts[:runs_scanned] += 1
      res = RunCatalogRemapByName.resolve(run)
      project = run.project

      case res.outcome
      when :missing_project
        counts[:runs_missing_project] += 1
      when :skipped_catalog_version_id_lte_3
        counts[:runs_skipped_catalog_version_id_lte_3] += 1
        if verbose && project
          v = project.version_for_catalog
          puts "SKIP run_id=#{run.id} project_id=#{run.project_id}: catalog version_id=#{v&.id.inspect} " \
               "not greater than 3 (projects.version_id=#{project.version_id.inspect})"
        end
      when :no_catalog_docker
        counts[:runs_project_no_catalog_version_or_docker] += 1
        if verbose && project
          v = project.version_for_catalog
          puts "FAIL run_id=#{run.id} project_id=#{run.project_id}: no asap_docker for catalog version_id=#{v.id} " \
               "(projects.version_id=#{project.version_id.inspect})"
        end
      when :no_step_row
        counts[:runs_fail_no_step_row] += 1
        if verbose && project
          puts "FAIL run_id=#{run.id} project_id=#{project.id}: missing step row step_id=#{run.step_id}"
        end
      when :no_catalog_step
        counts[:runs_fail_no_catalog_step_for_name] += 1
        if verbose && project
          st = run.step
          v = project.version_for_catalog
          img = project.asap_docker_image_for_catalog
          puts "FAIL run_id=#{run.id} project_id=#{project.id} key=#{project.key}: no catalog step name=#{st.name.inspect} " \
               "catalog_version_id=#{v.id} catalog_docker_image_id=#{img.id}"
        end
      when :ambiguous_step
        counts[:runs_fail_ambiguous_catalog_step_name] += 1
        if verbose && project
          st = run.step
          step_rows = project.catalog_steps.where(name: st.name).to_a
          puts "FAIL run_id=#{run.id} project_id=#{project.id}: ambiguous catalog steps name=#{st.name.inspect} ids=#{step_rows.map(&:id).inspect}"
        end
      when :missing_current_std_method_row
        counts[:runs_fail_missing_current_std_method_row] += 1
        if verbose
          puts "FAIL run_id=#{run.id} std_method_id=#{run.std_method_id}: row missing"
        end
      when :no_catalog_std_method
        counts[:runs_fail_no_catalog_std_method_for_name] += 1
        if verbose && project
          st = run.step
          sm = StdMethod.find_by(id: run.std_method_id)
          step_rows = project.catalog_steps.where(name: st.name).to_a
          mapped_step_id = step_rows.first.id
          puts "FAIL run_id=#{run.id} project_id=#{project.id}: no catalog std_method name=#{sm&.name.inspect} on step_id=#{mapped_step_id}"
        end
      when :ambiguous_std_method
        counts[:runs_fail_ambiguous_catalog_std_method_name] += 1
        if verbose && project
          st = run.step
          sm = run.std_method || StdMethod.find_by(id: run.std_method_id)
          step_rows = project.catalog_steps.where(name: st.name).to_a
          mapped_step_id = step_rows.first.id
          std_rows = project.catalog_std_methods(include_obsolete: true).where(step_id: mapped_step_id).where(name: sm.name).to_a
          obs = std_rows.map { |r| "#{r.id}:#{r.obsolete}" }.join(",")
          puts "FAIL run_id=#{run.id} ambiguous std_methods name=#{sm.name.inspect} step_id=#{mapped_step_id} rows=#{obs}"
        end
      when :no_change
        counts[:runs_no_change_needed] += 1
      when :remap
        counts[:runs_would_remap] += 1
        ms = res.mapped_step_id
        mm = res.mapped_std_method_id
        if ms != run.step_id && mm != run.std_method_id
          counts[:runs_would_change_step_and_std_method_id] += 1
        elsif ms != run.step_id
          counts[:runs_would_change_step_id_only] += 1
        else
          counts[:runs_would_change_std_method_id_only] += 1
        end
      else
        raise "unknown outcome #{res.outcome.inspect}"
      end
    end

    known_keys = %i[
      runs_scanned runs_missing_project runs_skipped_catalog_version_id_lte_3 runs_project_no_catalog_version_or_docker
      runs_fail_no_step_row
      runs_fail_no_catalog_step_for_name runs_fail_ambiguous_catalog_step_name
      runs_fail_missing_current_std_method_row runs_fail_no_catalog_std_method_for_name
      runs_fail_ambiguous_catalog_std_method_name runs_no_change_needed runs_would_remap
      runs_would_change_step_id_only runs_would_change_std_method_id_only runs_would_change_step_and_std_method_id
    ]
    puts "[runs:simulate_remap_runs_to_project_catalog_by_name] runs_scanned=#{counts[:runs_scanned]}"
    puts "  #{known_keys.map { |k| "#{k}=#{counts[k]}" }.join(' ')}"
    puts "[runs:simulate_remap_runs_to_project_catalog_by_name] done"
  end

  desc <<~DESC.squish
    Updates runs.step_id and runs.std_method_id so each run matches the project catalog using the same rules as
    runs:simulate_remap_runs_to_project_catalog_by_name (step name, std method name, obsolete allowed, unique
    non-obsolete tie-break, catalog version id must be greater than 3). Preflight: if any run would hit a hard
    failure outcome (anything other than no_change, remap, or skipped_catalog_version_id_lte_3), the task aborts
    without writing. Requires CONFIRM=remap_runs_to_catalog. PROJECT_IDS=id,... RUN_IDS=id,... optional.
    VERBOSE=1 logs each updated run.
  DESC
  task apply_remap_to_project_catalog_by_name: :environment do
    unless ENV["CONFIRM"] == "remap_runs_to_catalog"
      raise "Refusing to run: set environment CONFIRM=remap_runs_to_catalog"
    end

    project_ids = ENV["PROJECT_IDS"].to_s.split(",").map(&:strip).map(&:to_i).reject(&:zero?)
    run_ids = ENV["RUN_IDS"].to_s.split(",").map(&:strip).map(&:to_i).reject(&:zero?)
    verbose = ENV["VERBOSE"] == "1"

    hard_fail_outcomes = %i[
      missing_project no_catalog_docker no_step_row no_catalog_step ambiguous_step
      missing_current_std_method_row no_catalog_std_method ambiguous_std_method
    ].freeze

    run_scope = Run.includes(:project, :step, :std_method).references(:project)
    run_scope = run_scope.where(project_id: project_ids) if project_ids.any?
    run_scope = run_scope.where(id: run_ids) if run_ids.any?

    preflight = Hash.new(0)
    run_scope.find_each do |run|
      preflight[RunCatalogRemapByName.resolve(run).outcome] += 1
    end

    hard_fail_runs = hard_fail_outcomes.sum { |o| preflight[o] }
    if hard_fail_runs.positive?
      raise "Preflight failed: #{hard_fail_outcomes.map { |o| "#{o}=#{preflight[o]}" }.join(' ')}. No updates applied."
    end

    counts = Hash.new(0)
    run_scope.find_each do |run|
      counts[:runs_scanned] += 1
      res = RunCatalogRemapByName.resolve(run)
      case res.outcome
      when :no_change
        counts[:runs_unchanged] += 1
      when :skipped_catalog_version_id_lte_3
        counts[:runs_skipped_catalog_version_id_lte_3] += 1
      when :remap
        run.update!(step_id: res.mapped_step_id, std_method_id: res.mapped_std_method_id)
        counts[:runs_updated] += 1
        if verbose
          puts "UPDATED run_id=#{run.id} project_id=#{run.project_id} step_id=#{res.mapped_step_id} std_method_id=#{res.mapped_std_method_id.inspect}"
        end
      else
        raise "Preflight drift: unexpected outcome #{res.outcome.inspect} for run_id=#{run.id}"
      end
    end

    puts "[runs:apply_remap_to_project_catalog_by_name] runs_scanned=#{counts[:runs_scanned]}"
    puts "  runs_updated=#{counts[:runs_updated]} runs_unchanged=#{counts[:runs_unchanged]} " \
         "runs_skipped_catalog_version_id_lte_3=#{counts[:runs_skipped_catalog_version_id_lte_3]}"
    puts "[runs:apply_remap_to_project_catalog_by_name] done"
  end
end
