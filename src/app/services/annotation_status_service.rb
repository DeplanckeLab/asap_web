# frozen_string_literal: true

# Computes and persists annotation status per (annot_id, cat_idx).
#
# Rules (same as UI):
# - consensus: best active CLA has nber_agree >= 2 and score > 0
# - annotated: at least one active CLA
# - markers_ready: FindMarkers completed for this metadata, no CLA yet
# - none: otherwise
class AnnotationStatusService
  class << self
    def refresh!(annot:, cat_idx:, markers_run: nil)
      new(annot: annot).refresh_category!(cat_idx: cat_idx, markers_run: markers_run)
    end

    def refresh_annot!(annot:, markers_run: nil)
      new(annot: annot, markers_run: markers_run).refresh_all_categories!
    end

    def refresh_for_markers_run!(run)
      return unless run
      return unless run.step&.name == 'markers'
      return unless run.status_id.to_i == 3

      annot_id = run.marker_metadata_annot_id
      return unless annot_id

      annot = Annot.find_by(id: annot_id)
      return unless annot

      refresh_annot!(annot: annot, markers_run: run)
    end

    def refresh_for_cell_set!(cell_set_id)
      return if cell_set_id.blank?

      AnnotCellSet.where(cell_set_id: cell_set_id).find_each do |acs|
        annot = acs.annot
        next unless annot

        refresh!(annot: annot, cat_idx: acs.cat_idx)
      end
    end

    def backfill_all!
      now = Time.current
      AnnotCellSet.find_in_batches(batch_size: 1000) do |batch|
        cell_set_ids = batch.filter_map(&:cell_set_id).uniq
        best_by_cell_set = {}
        if cell_set_ids.any?
          Cla.active.where(cell_set_id: cell_set_ids).find_each do |cla|
            csid = cla.cell_set_id
            score = cla.nber_agree.to_i - cla.nber_disagree.to_i
            prev = best_by_cell_set[csid]
            next if prev && (prev[:score] > score || (prev[:score] == score && prev[:created_at].to_i >= cla.created_at.to_i))

            best_by_cell_set[csid] = {
              id: cla.id,
              score: score,
              nber_agree: cla.nber_agree.to_i,
              created_at: cla.created_at
            }
          end
        end

        rows = batch.filter_map do |acs|
          next unless acs.annot_id && acs.project_id

          best = acs.cell_set_id ? best_by_cell_set[acs.cell_set_id] : nil
          status = 'none'
          best_cla_id = nil
          if best
            status = (best[:nber_agree] >= 2 && best[:score].positive?) ? 'consensus' : 'annotated'
            best_cla_id = best[:id]
          end

          {
            project_id: acs.project_id,
            annot_id: acs.annot_id,
            cat_idx: acs.cat_idx.to_i,
            cell_set_id: acs.cell_set_id,
            status: status,
            best_cla_id: best_cla_id,
            markers_run_id: nil,
            computed_at: now,
            created_at: now,
            updated_at: now
          }
        end

        next if rows.empty?

        AnnotationStatus.upsert_all(
          rows,
          unique_by: %i[annot_id cat_idx],
          update_only: %i[project_id cell_set_id status best_cla_id markers_run_id computed_at]
        )
      end
    end

    def completed_markers_runs_by_annot_id(annot_ids)
      ids = Array(annot_ids).map(&:to_i).select(&:positive?).uniq
      return {} if ids.empty?

      marker_step_ids = Step.where(name: 'markers').pluck(:id)
      return {} if marker_step_ids.empty?

      # Limit to candidate runs for these projects to avoid scanning every markers run.
      project_ids = Annot.where(id: ids).distinct.pluck(:project_id)
      runs = Run.where(step_id: marker_step_ids, status_id: 3, project_id: project_ids).order(id: :desc).limit(5000).to_a
      by_annot = {}
      runs.each do |run|
        aid = run.marker_metadata_annot_id
        next unless aid && ids.include?(aid.to_i)
        next if by_annot.key?(aid.to_i)

        by_annot[aid.to_i] = run
      end
      by_annot
    end
  end

  def initialize(annot:, markers_run: nil)
    @annot = annot
    @project = annot.project
    @markers_run = markers_run
  end

  def refresh_all_categories!
    cat_idxs = AnnotCellSet.where(annot_id: @annot.id).distinct.pluck(:cat_idx)
    if cat_idxs.empty?
      list_cats = Basic.safe_parse_json(@annot.list_cat_json, [])
      cat_idxs = list_cats.is_a?(Array) ? (0...list_cats.size).to_a : []
    end
    cat_idxs.each { |idx| refresh_category!(cat_idx: idx) }
  end

  def refresh_category!(cat_idx:, cell_set_id: nil, markers_run: nil)
    cat_idx = cat_idx.to_i
    # markers_run:
    # - nil  => look up completed markers run
    # - false => skip markers lookup (bulk CLA-only backfill)
    # - Run  => use provided run
    resolved_markers_run =
      if markers_run == false
        nil
      elsif markers_run
        markers_run
      else
        @markers_run || completed_markers_run_for_annot
      end
    acs = AnnotCellSet.find_by(annot_id: @annot.id, cat_idx: cat_idx)
    cell_set_id = cell_set_id.presence || acs&.cell_set_id

    best = best_active_cla(cell_set_id)
    status = compute_status(best_cla: best, markers_run: resolved_markers_run)

    row = AnnotationStatus.find_or_initialize_by(annot_id: @annot.id, cat_idx: cat_idx)
    row.project_id = @annot.project_id
    row.cell_set_id = cell_set_id
    row.status = status
    row.best_cla_id = best&.id
    row.markers_run_id = resolved_markers_run&.id
    row.computed_at = Time.current
    row.save!
    row
  end

  private

  def compute_status(best_cla:, markers_run:)
    if best_cla
      agree = best_cla.nber_agree.to_i
      score = agree - best_cla.nber_disagree.to_i
      return 'consensus' if agree >= 2 && score.positive?
      return 'annotated'
    end
    return 'markers_ready' if markers_run
    'none'
  end

  def best_active_cla(cell_set_id)
    return nil if cell_set_id.blank?

    Cla.active.where(cell_set_id: cell_set_id)
       .order(Arel.sql('(COALESCE(nber_agree,0) - COALESCE(nber_disagree,0)) DESC, created_at DESC'))
       .first
  end

  def completed_markers_run_for_annot
    self.class.completed_markers_runs_by_annot_id([@annot.id])[@annot.id]
  end
end
