# frozen_string_literal: true

# Mode A (R-M1a): from a target project + cell set identity, list other readable projects
# in the same {ProjectCellSet} and compatible {Annot} rows linked to that {CellSet}.
#
# Callers supply +readable_if+ as a proc +Project+ -> Boolean (+readable?+ from authorization).
class MetadataImportModeADiscoveryService
  class << self
    def call(target_project:, readable_if:, cell_set_id: nil, cell_set_key: nil)
      new(
        target_project: target_project,
        readable_if: readable_if,
        cell_set_id: cell_set_id,
        cell_set_key: cell_set_key
      ).call
    end
  end

  def initialize(target_project:, readable_if:, cell_set_id:, cell_set_key:)
    @target = target_project
    @readable_if = readable_if
    @cell_set_id = cell_set_id
    @cell_set_key = cell_set_key.to_s.strip.presence
  end

  def call
    return error_payload("Target project is missing.", :unprocessable_entity) unless @target

    pcs_id = @target.project_cell_set_id
    return error_payload("This project has no cell-set identity (project_cell_set_id).", :unprocessable_entity) unless pcs_id

    cell_set = resolve_cell_set(pcs_id)
    return error_payload("Cell set not found or not part of this project's cell-set identity.", :not_found) unless cell_set

    sources = Project.where(project_cell_set_id: pcs_id)
                     .where.not(id: @target.id)
                     .order(:id)
                     .to_a
                     .select { |p| @readable_if.call(p) }

    h = MetadataImportDiscoveryHelpers
    payload = {
      target_project: h.project_summary(@target),
      cell_set: { id: cell_set.id, key: cell_set.key.to_s },
      sources: sources.map { |source| build_source_entry(source, cell_set, h) }
    }

    { ok: true, payload: payload }
  end

  private

  def error_payload(message, status)
    { ok: false, error: message, status: status }
  end

  def resolve_cell_set(pcs_id)
    if @cell_set_id.present? && @cell_set_id.to_i.positive?
      cs = CellSet.find_by(id: @cell_set_id.to_i)
      return cs if cs && cs.project_cell_set_id == pcs_id

      return nil
    end

    return nil if @cell_set_key.blank?

    CellSet.find_by(project_cell_set_id: pcs_id, key: @cell_set_key)
  end

  def build_source_entry(source, cell_set, h)
    dim = h.dimension_alignment(@target, source)
    annots = eligible_annots_for_cell_set(source, cell_set)

    {
      project: h.project_summary(source),
      dimensions_aligned: dim[:aligned],
      dimensions_check: dim[:check],
      annots: annots.map { |a| h.annot_import_payload(@target, a, dim) }
    }
  end

  def eligible_annots_for_cell_set(source, cell_set)
    Annot.joins(:annot_cell_sets)
         .where(project_id: source.id, annot_cell_sets: { cell_set_id: cell_set.id })
         .where(latest_version: true)
         .where("annots.name LIKE ? OR annots.name LIKE ?", "/col_attrs/%", "/row_attrs/%")
         .includes(:data_type)
         .order("annots.name ASC")
         .distinct
  end
end
