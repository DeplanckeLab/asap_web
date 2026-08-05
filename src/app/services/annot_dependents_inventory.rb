# frozen_string_literal: true

# Lists project artifacts that become obsolete if a discrete metadata Annot is
# deleted (not archived) during a rewrite.
class AnnotDependentsInventory
  CONSENSUS_PATH_PREFIX = "/col_attrs/_asap_consensus_"
  CELL_SELECTION_STEP_NAME = "cell_selection"

  Result = Struct.new(
    :annot_id,
    :annot_name,
    :annot_label,
    :selections,
    :runs,
    :cla_count,
    :annot_cell_set_count,
    :manual_review,
    :run_ids_to_delete,
    keyword_init: true
  ) do
    def has_cascade_targets?
      Array(run_ids_to_delete).any?
    end

    def as_json(_options = nil)
      {
        annot_id: annot_id,
        annot_name: annot_name,
        annot_label: annot_label,
        selections: selections,
        runs: runs,
        cla_count: cla_count,
        annot_cell_set_count: annot_cell_set_count,
        manual_review: manual_review,
        run_ids_to_delete: run_ids_to_delete,
        summary: {
          selection_count: Array(selections).size,
          run_count: Array(runs).size,
          run_ids_to_delete_count: Array(run_ids_to_delete).size,
          cla_count: cla_count.to_i,
          annot_cell_set_count: annot_cell_set_count.to_i,
          manual_review_count: Array(manual_review).size,
          has_cascade_targets: has_cascade_targets?
        }
      }
    end
  end

  class << self
    def call(project:, annot:)
      new(project: project, annot: annot).call
    end

    def merge_results(results)
      list = Array(results).compact
      return nil if list.empty?

      run_ids = list.flat_map { |r| Array(r.run_ids_to_delete) }.map(&:to_i).uniq.select(&:positive?)
      {
        annots: list.map(&:as_json),
        run_ids_to_delete: run_ids,
        summary: {
          annot_count: list.size,
          selection_count: list.sum { |r| Array(r.selections).size },
          run_count: list.sum { |r| Array(r.runs).size },
          run_ids_to_delete_count: run_ids.size,
          cla_count: list.sum { |r| r.cla_count.to_i },
          annot_cell_set_count: list.sum { |r| r.annot_cell_set_count.to_i },
          manual_review_count: list.sum { |r| Array(r.manual_review).size },
          has_cascade_targets: run_ids.any?
        }
      }
    end
  end

  def initialize(project:, annot:)
    @project = project
    @annot = annot
  end

  def call
    return empty_result unless @project && @annot

    selection_entries, selection_run_ids = collect_selection_dependents
    other_run_entries, other_run_ids = collect_other_run_dependents(exclude_run_ids: selection_run_ids)
    child_run_entries = collect_descendant_run_entries(selection_run_ids | other_run_ids)

    runs = (other_run_entries + child_run_entries).uniq { |entry| entry[:run_id] }
    run_ids_to_delete = (selection_run_ids | other_run_ids | child_run_entries.map { |e| e[:run_id] }).uniq.sort

    Result.new(
      annot_id: @annot.id,
      annot_name: @annot.name.to_s,
      annot_label: (@annot.label.presence || @annot.name.to_s.split("/").last).to_s,
      selections: selection_entries,
      runs: runs,
      cla_count: Cla.where(annot_id: @annot.id).count,
      annot_cell_set_count: AnnotCellSet.where(annot_id: @annot.id).count,
      manual_review: manual_review_entries(run_ids_to_delete),
      run_ids_to_delete: run_ids_to_delete
    )
  end

  private

  def empty_result
    Result.new(
      annot_id: nil,
      annot_name: nil,
      annot_label: nil,
      selections: [],
      runs: [],
      cla_count: 0,
      annot_cell_set_count: 0,
      manual_review: [],
      run_ids_to_delete: []
    )
  end

  def cell_selection_step_ids
    @cell_selection_step_ids ||= Step.where(name: CELL_SELECTION_STEP_NAME).pluck(:id)
  end

  def collect_selection_dependents
    entries = []
    direct_run_ids = []
    return [entries, direct_run_ids] if cell_selection_step_ids.empty?

    selection_runs = Run.where(project_id: @project.id, step_id: cell_selection_step_ids).to_a
    by_id = selection_runs.index_by(&:id)
    attrs_by_id = {}
    selection_runs.each do |run|
      attrs_by_id[run.id] = Basic.safe_parse_json(run.attrs_json, {})
    end

    selection_runs.each do |run|
      attrs = attrs_by_id[run.id] || {}
      reasons = selection_reference_reasons(attrs, @annot.id)
      next if reasons.empty?

      direct_run_ids << run.id
      entries << selection_entry(run, attrs, reasons)
    end

    pending = direct_run_ids.dup
    seen = direct_run_ids.to_set
    while pending.any?
      current_id = pending.shift
      current_run = by_id[current_id]
      next unless current_run

      selection_ref_keys = selection_identity_keys(current_run, attrs_by_id[current_id] || {})
      selection_runs.each do |run|
        next if seen.include?(run.id)

        attrs = attrs_by_id[run.id] || {}
        reasons = selection_depends_on_selection_reasons(attrs, selection_ref_keys)
        next if reasons.empty?

        seen << run.id
        pending << run.id
        entries << selection_entry(run, attrs, reasons)
      end
    end

    [entries, seen.to_a]
  end

  def selection_reference_reasons(attrs, annot_id)
    reasons = []
    aid = annot_id.to_i

    Array(attrs["filter_components"] || attrs[:filter_components]).each do |component|
      next unless component.is_a?(Hash)

      metadata_id = (component["metadata_id"] || component[:metadata_id]).to_i
      reasons << "filter" if metadata_id.positive? && metadata_id == aid
    end

    Array(attrs["compose_steps"] || attrs[:compose_steps]).each do |step|
      next unless step.is_a?(Hash)

      %w[operand_a operand_b].each do |key|
        raw = (step[key] || step[key.to_sym]).to_s
        next unless raw.start_with?("cat:")

        parts = raw.split(":")
        reasons << "compose" if parts[1].to_i == aid
      end

      %w[operand_a_annot_id operand_b_annot_id].each do |key|
        reasons << "compose" if (step[key] || step[key.to_sym]).to_i == aid
      end
    end

    reasons.uniq
  end

  def selection_identity_keys(run, attrs)
    keys = ["run:#{run.id}"]
    selection_id = (attrs["selection_id"] || attrs[:selection_id]).to_s
    keys << "selection:#{selection_id}" if selection_id.present?
    meta_name = (attrs["selection_metadata_name"] || attrs[:selection_metadata_name]).to_s
    keys << "meta:#{meta_name}" if meta_name.present?
    annot = Annot.find_by(run_id: run.id, project_id: @project.id)
    keys << "annot:#{annot.id}" if annot
    keys << "saved:#{annot.id}" if annot
    keys << "saved:annot-#{annot.id}" if annot
    keys
  end

  def selection_depends_on_selection_reasons(attrs, target_keys)
    reasons = []
    key_set = target_keys.to_set

    Array(attrs["filter_components"] || attrs[:filter_components]).each do |component|
      next unless component.is_a?(Hash)

      ref = (component["selection_ref_id"] || component[:selection_ref_id]).to_s
      next if ref.blank?

      candidates = ["selection:#{ref}", "saved:#{ref}", ref]
      reasons << "filter_selection_ref" if candidates.any? { |c| key_set.include?(c) }
    end

    Array(attrs["compose_steps"] || attrs[:compose_steps]).each do |step|
      next unless step.is_a?(Hash)

      %w[operand_a operand_b].each do |key|
        raw = (step[key] || step[key.to_sym]).to_s
        next unless raw.start_with?("saved:")

        sel_id = raw.delete_prefix("saved:")
        candidates = ["saved:#{sel_id}", "selection:#{sel_id}", "annot:#{sel_id.delete_prefix('annot-')}"]
        reasons << "compose_selection_ref" if candidates.any? { |c| key_set.include?(c) }
      end
    end

    reasons.uniq
  end

  def selection_entry(run, attrs, reasons)
    {
      run_id: run.id,
      selection_name: (attrs["selected_name"] || attrs[:selected_name] || attrs["selection_metadata_name"] || "Selection").to_s,
      selection_metadata_name: (attrs["selection_metadata_name"] || attrs[:selection_metadata_name]).to_s,
      selection_source: (attrs["selection_source"] || attrs[:selection_source]).to_s,
      reasons: reasons
    }
  end

  def collect_other_run_dependents(exclude_run_ids:)
    exclude = exclude_run_ids.to_set
    run_ids = RunAnnotReferenceScanner.run_ids_referencing_annot(@project.id, @annot)
                                     .reject { |id| exclude.include?(id) }
    runs = Run.where(id: run_ids).includes(:step).to_a
    entries = runs.map do |run|
      {
        run_id: run.id,
        step_name: run.step&.name.to_s,
        step_label: run.step&.label.to_s.presence || run.step&.name.to_s,
        num: run.num,
        reason: "annot_reference"
      }
    end
    [entries, run_ids]
  end

  def collect_descendant_run_entries(seed_run_ids)
    entries = []
    pending = seed_run_ids.map(&:to_i)
    seen = pending.to_set

    while pending.any?
      run = Run.find_by(id: pending.shift, project_id: @project.id)
      next unless run

      children = run.children_run_ids.to_s.split(",").map(&:strip).map(&:to_i).select(&:positive?)
      children.each do |child_id|
        next if seen.include?(child_id)

        seen << child_id
        pending << child_id
        child = Run.find_by(id: child_id, project_id: @project.id)
        next unless child

        entries << {
          run_id: child.id,
          step_name: child.step&.name.to_s,
          step_label: child.step&.label.to_s.presence || child.step&.name.to_s,
          num: child.num,
          reason: "downstream_of_dependent"
        }
      end
    end

    entries
  end

  def manual_review_entries(run_ids_to_delete)
    entries = []
    de_run_ids = Run.joins(:step)
                    .where(id: run_ids_to_delete, project_id: @project.id)
                    .where(steps: { name: "de" })
                    .pluck(:id)
    return entries if de_run_ids.empty?

    from_de_type = GeneSetCollectionType.find_by(key: "from_de")
    return entries unless from_de_type

    GeneSetCollection.where(project_id: @project.id, gene_set_collection_type_id: from_de_type.id).find_each do |collection|
      entries << {
        type: "gene_set_collection_from_de",
        id: collection.id,
        name: collection.name.to_s,
        message: "FROM_DE gene set collection is not linked to a specific DE run and will not be auto-deleted."
      }
    end
    entries
  end
end
