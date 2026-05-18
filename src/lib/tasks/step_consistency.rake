# Audits Run or DelRun rows: non-blank std_method_id must reference a StdMethod whose
# version_id and docker_image_id match the project (docker via Basic.get_asap_docker).
class StdMethodRunAudit
  def self.run(model:, id_label:, row_plural:, verbose:, limit_projects:, max_detail:)
    stats = {
      projects: 0,
      projects_with_rows: 0,
      projects_with_issues: 0,
      projects_no_version: 0,
      projects_asap_docker_unresolved: 0,
      rows_total: 0,
      rows_with_std_method: 0,
      rows_flagged: 0
    }

    processed = 0
    Project.order(:id).find_each do |p|
      break if limit_projects && processed >= limit_projects

      processed += 1
      stats[:projects] += 1

      if p.version_id.blank?
        stats[:projects_no_version] += 1
        n = model.where(project_id: p.id).count
        stats[:rows_total] += n
        if n.positive?
          rows_with_sm = model.where(project_id: p.id).where.not(std_method_id: nil).count
          stats[:rows_with_std_method] += rows_with_sm
          stats[:projects_with_issues] += 1
          stats[:rows_flagged] += rows_with_sm
          puts "project id=#{p.id} key=#{p.key} ISSUE: project.version_id is blank (#{n} #{row_plural}, #{rows_with_sm} with std_method_id)"
        elsif verbose
          puts "project id=#{p.id} key=#{p.key} project.version_id is blank (no #{row_plural})"
        end
        next
      end

      img = Basic.get_asap_docker(p.version)
      if img.nil?
        stats[:projects_asap_docker_unresolved] += 1
        if verbose
          puts "project id=#{p.id} key=#{p.key} version_id=#{p.version_id} WARN: Basic.get_asap_docker returned nil (docker not compared)"
        end
      end

      rows = model.where(project_id: p.id).pluck(:id, :std_method_id)
      stats[:rows_total] += rows.size
      if rows.empty?
        puts "project id=#{p.id} key=#{p.key} version_id=#{p.version_id} (no #{row_plural})" if verbose
        next
      end

      stats[:projects_with_rows] += 1

      rows_with_sm = rows.select { |_, smid| smid.present? }
      stats[:rows_with_std_method] += rows_with_sm.size

      sm_ids = rows_with_sm.map { |_, smid| smid }.uniq
      sm_h = StdMethod.where(id: sm_ids).index_by(&:id)

      flagged = []
      rows_with_sm.each do |row_id, smid|
        problems = []
        sm = sm_h[smid]
        unless sm
          problems << "no StdMethod for std_method_id=#{smid}"
        else
          if sm.version_id != p.version_id
            problems << "std_method.version_id=#{sm.version_id} != project.version_id=#{p.version_id}"
          end
          if img && sm.docker_image_id != img.id
            problems << "std_method.docker_image_id=#{sm.docker_image_id} != get_asap_docker.id=#{img.id}"
          end
        end
        next if problems.empty?

        flagged << { row_id: row_id, std_method_id: smid, problems: problems }
      end

      if flagged.empty?
        if verbose
          extra = rows_with_sm.size != rows.size ? " with_std_method=#{rows_with_sm.size}" : ""
          puts "project id=#{p.id} key=#{p.key} version_id=#{p.version_id} #{row_plural}=#{rows.size}#{extra} OK"
        end
        next
      end

      stats[:projects_with_issues] += 1
      stats[:rows_flagged] += flagged.size
      puts "project id=#{p.id} key=#{p.key} version_id=#{p.version_id} asap_docker_id=#{img&.id.inspect} incompatible_#{row_plural}=#{flagged.size}"
      flagged.first(max_detail).each do |row|
        puts "  #{id_label}=#{row[:row_id]} std_method_id=#{row[:std_method_id].inspect} #{row[:problems].join('; ')}"
      end
      puts "  (#{flagged.size - max_detail} more)" if flagged.size > max_detail
    end

    puts ""
    puts "Summary (#{row_plural}):"
    puts "  projects_scanned=#{stats[:projects]}"
    puts "  projects_with_#{row_plural}=#{stats[:projects_with_rows]}"
    puts "  projects_no_version=#{stats[:projects_no_version]}"
    puts "  projects_asap_docker_unresolved=#{stats[:projects_asap_docker_unresolved]} (docker not compared; WARN if VERBOSE=1)"
    puts "  projects_with_issues=#{stats[:projects_with_issues]}"
    puts "  #{row_plural}_total=#{stats[:rows_total]}"
    puts "  #{row_plural}_with_std_method=#{stats[:rows_with_std_method]}"
    puts "  #{row_plural}_flagged=#{stats[:rows_flagged]}"
    stats
  end
end

namespace :steps do
  desc "For every project, check each Run: Step exists, step.version_id matches project.version_id, " \
       "and step.docker_image_id matches Basic.get_asap_docker(project.version). " \
       "ENV: VERBOSE=1 (print projects with no runs or all OK), LIMIT_PROJECTS=N, MAX_RUN_DETAIL=N (default 15)."
  task audit_project_run_steps: :environment do
    verbose = ENV["VERBOSE"].to_s == "1"
    limit_projects = ENV["LIMIT_PROJECTS"].presence&.to_i
    max_detail = ENV["MAX_RUN_DETAIL"].presence&.to_i || 15

    stats = {
      projects: 0,
      projects_with_runs: 0,
      projects_with_issues: 0,
      projects_no_version: 0,
      projects_asap_docker_unresolved: 0,
      runs_total: 0,
      runs_flagged: 0
    }

    processed = 0
    Project.order(:id).find_each do |p|
      break if limit_projects && processed >= limit_projects

      processed += 1
      stats[:projects] += 1

      if p.version_id.blank?
        stats[:projects_no_version] += 1
        n = Run.where(project_id: p.id).count
        stats[:runs_total] += n
        if n.positive?
          stats[:projects_with_issues] += 1
          stats[:runs_flagged] += n
          puts "project id=#{p.id} key=#{p.key} ISSUE: project.version_id is blank (#{n} runs)"
        elsif verbose
          puts "project id=#{p.id} key=#{p.key} project.version_id is blank (no runs)"
        end
        next
      end

      img = Basic.get_asap_docker(p.version)
      if img.nil?
        stats[:projects_asap_docker_unresolved] += 1
        puts "project id=#{p.id} key=#{p.key} version_id=#{p.version_id} WARN: Basic.get_asap_docker returned nil (docker not compared)" if verbose
      end

      run_rows = Run.where(project_id: p.id).pluck(:id, :step_id)
      stats[:runs_total] += run_rows.size
      if run_rows.empty?
        puts "project id=#{p.id} key=#{p.key} version_id=#{p.version_id} (no runs)" if verbose
        next
      end

      stats[:projects_with_runs] += 1

      step_ids = run_rows.map { |_, sid| sid }.compact.uniq
      steps_h = Step.where(id: step_ids).index_by(&:id)

      flagged = []
      run_rows.each do |run_id, step_id|
        problems = []
        if step_id.blank?
          problems << "run has blank step_id"
        else
          st = steps_h[step_id]
          unless st
            problems << "no Step for step_id=#{step_id}"
          else
            if st.version_id != p.version_id
              problems << "step.version_id=#{st.version_id} != project.version_id=#{p.version_id}"
            end
            if img && st.docker_image_id != img.id
              problems << "step.docker_image_id=#{st.docker_image_id} != get_asap_docker.id=#{img.id}"
            end
          end
        end
        next if problems.empty?

        flagged << { run_id: run_id, step_id: step_id, problems: problems }
      end

      if flagged.empty?
        puts "project id=#{p.id} key=#{p.key} version_id=#{p.version_id} runs=#{run_rows.size} OK" if verbose
        next
      end

      stats[:projects_with_issues] += 1
      stats[:runs_flagged] += flagged.size
      puts "project id=#{p.id} key=#{p.key} version_id=#{p.version_id} asap_docker_id=#{img&.id.inspect} incompatible_runs=#{flagged.size}"
      flagged.first(max_detail).each do |row|
        puts "  run_id=#{row[:run_id]} step_id=#{row[:step_id].inspect} #{row[:problems].join('; ')}"
      end
      puts "  (#{flagged.size - max_detail} more)" if flagged.size > max_detail
    end

    puts ""
    puts "Summary:"
    puts "  projects_scanned=#{stats[:projects]}"
    puts "  projects_with_runs=#{stats[:projects_with_runs]}"
    puts "  projects_no_version=#{stats[:projects_no_version]}"
    puts "  projects_asap_docker_unresolved=#{stats[:projects_asap_docker_unresolved]} (docker not compared; WARN if VERBOSE=1)"
    puts "  projects_with_issues=#{stats[:projects_with_issues]} (blank version with runs, or incompatible runs)"
    puts "  runs_total=#{stats[:runs_total]}"
    puts "  runs_flagged=#{stats[:runs_flagged]}"
  end

  desc "For every project, check each Run with std_method_id: StdMethod exists, version_id matches " \
       "project.version_id, docker_image_id matches Basic.get_asap_docker(project.version). " \
       "Rows with blank std_method_id are skipped. ENV: VERBOSE=1, LIMIT_PROJECTS=N, MAX_RUN_DETAIL=N (default 15), " \
       "INCLUDE_DEL_RUNS=1 to audit del_runs too."
  task audit_project_run_std_methods: :environment do
    verbose = ENV["VERBOSE"].to_s == "1"
    limit_projects = ENV["LIMIT_PROJECTS"].presence&.to_i
    max_detail = ENV["MAX_RUN_DETAIL"].presence&.to_i || 15

    puts "Run std_method compatibility"
    StdMethodRunAudit.run(
      model: Run,
      id_label: "run_id",
      row_plural: "runs",
      verbose: verbose,
      limit_projects: limit_projects,
      max_detail: max_detail
    )

    if ENV["INCLUDE_DEL_RUNS"].to_s == "1"
      puts ""
      puts "DelRun std_method compatibility (INCLUDE_DEL_RUNS=1)"
      StdMethodRunAudit.run(
        model: DelRun,
        id_label: "del_run_id",
        row_plural: "del_runs",
        verbose: verbose,
        limit_projects: limit_projects,
        max_detail: max_detail
      )
    end
  end

  desc "Audit a Step row vs projects and runs (version_id, docker_image_id vs Basic.get_asap_docker). " \
       "Default STEP_ID=72. Example: rails steps:audit_consistency STEP_ID=72"
  task audit_consistency: :environment do
    step_id = ENV["STEP_ID"].presence&.to_i || 72
    step = Step.find_by(id: step_id)
    unless step
      abort("Step id=#{step_id} not found")
    end

    puts "Step id=#{step.id} name=#{step.name} docker_image_id=#{step.docker_image_id} " \
         "version_id=#{step.version_id} group_name=#{step.group_name.inspect} hidden=#{step.hidden}"
    puts ""

    # --- Runs that reference this step
    run_scope = Run.where(step_id: step.id)
    run_count = run_scope.count
    puts "--- Runs with step_id=#{step.id} (total #{run_count}) ---"
    if run_count.zero?
      puts "(none)"
    else
      bad_version_runs = run_scope.joins(:project).where.not(projects: { version_id: step.version_id })
      puts "Runs whose project.version_id != step.version_id (#{step.version_id}): #{bad_version_runs.count}"
      bad_version_runs.limit(30).pluck("runs.id", "runs.project_id", "projects.key", "projects.version_id").each do |rid, pid, key, vid|
        puts "  run_id=#{rid} project_id=#{pid} key=#{key} project.version_id=#{vid}"
      end
      puts "  (truncated at 30)" if bad_version_runs.count > 30
    end
    puts ""

    # --- One line per project that has at least one such run
    project_ids = run_scope.distinct.pluck(:project_id).compact
    puts "--- Projects with at least one Run step_id=#{step.id} (#{project_ids.size} projects) ---"
    Project.where(id: project_ids).order(:id).find_each do |p|
      img = Basic.get_asap_docker(p.version)
      expected_docker = img&.id
      vid_ok = p.version_id == step.version_id
      docker_ok = expected_docker.present? && step.docker_image_id == expected_docker
      run_n = Run.where(project_id: p.id, step_id: step.id).count
      status =
        if vid_ok && docker_ok
          "OK"
        else
          issues = []
          issues << "version project=#{p.version_id} step=#{step.version_id}" unless vid_ok
          issues << "docker step=#{step.docker_image_id} get_asap_docker=#{expected_docker.inspect}" unless docker_ok
          "ISSUE: #{issues.join('; ')}"
        end
      puts "project id=#{p.id} key=#{p.key} version_id=#{p.version_id} runs=#{run_n} #{status}"
    end
    puts ""

    # --- All projects on the same version as the step (pipeline uses this cohort + resolved docker)
    same_ver = Project.where(version_id: step.version_id)
    same_ver_count = same_ver.count
    puts "--- Projects with version_id=#{step.version_id} (same as step; #{same_ver_count} projects) ---"
    docker_ok_n = 0
    docker_bad_n = 0
    asap_nil_n = 0
    same_ver.find_each do |p|
      img = Basic.get_asap_docker(p.version)
      if img.nil?
        asap_nil_n += 1
        next
      end
      if step.docker_image_id == img.id
        docker_ok_n += 1
      else
        docker_bad_n += 1
        puts "docker mismatch: project id=#{p.id} key=#{p.key} get_asap_docker=#{img.id} step.docker_image_id=#{step.docker_image_id}"
      end
    end
    puts "Summary same-version: docker_match=#{docker_ok_n} docker_mismatch=#{docker_bad_n} get_asap_docker_nil=#{asap_nil_n}"
  end
end
