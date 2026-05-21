# frozen_string_literal: true

# Resolves catalog step_id / std_method_id for a run from the project's version catalog,
# matching by step and std_method names (same rules as production alignment).
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

    sm = nil
    if run.std_method_id.present?
      sm = run.std_method || StdMethod.find_by(id: run.std_method_id)
      return Result.new(outcome: :missing_current_std_method_row) unless sm
    end

    step_name = catalog_step_name_for_run(st, sm)
    catalog_version_id = version.id
    step_rows = Step.where(version_id: catalog_version_id, name: step_name).to_a
    return Result.new(outcome: :no_catalog_step) if step_rows.empty?
    return Result.new(outcome: :ambiguous_step) if step_rows.size > 1

    mapped_step_id = step_rows.first.id
    mapped_std_method_id = nil

    if sm
      std_rows = StdMethod.where(version_id: catalog_version_id, step_id: mapped_step_id, name: sm.name).to_a
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

  # v7+ pipeline uses step pca_sc for std_method pca_seurat (not hidden step pca).
  def catalog_step_name_for_run(step, std_method)
    if step.name == "pca" && std_method&.name == "pca_seurat"
      "pca_sc"
    else
      step.name
    end
  end
end
