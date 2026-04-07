# frozen_string_literal: true

# Mode B (R-M1b, R-M1c): given a readable source project, list import candidates on that project
# that belong to the same {project_cell_set_id} universe as the target (via {AnnotCellSet} -> {CellSet}).
#
# Callers supply +readable_if+ as a proc +Project+ -> Boolean.
class MetadataImportModeBDiscoveryService
  class << self
    def call(target_project:, readable_if:, source_project_id: nil, source_project_key: nil)
      new(
        target_project: target_project,
        readable_if: readable_if,
        source_project_id: source_project_id,
        source_project_key: source_project_key
      ).call
    end
  end

  def initialize(target_project:, readable_if:, source_project_id:, source_project_key:)
    @target = target_project
    @readable_if = readable_if
    @source_project_id = source_project_id
    @source_project_key = source_project_key.to_s.strip.presence
  end

  def call
    return error_payload("Target project is missing.", :unprocessable_entity) unless @target

    pcs_id = @target.project_cell_set_id
    return error_payload("This project has no cell-set identity (project_cell_set_id).", :unprocessable_entity) unless pcs_id

    source = resolve_source_project
    unless source
      return error_payload("Source project not found.", :not_found)
    end

    unless @readable_if.call(source)
      return error_payload("You do not have access to that project.", :forbidden)
    end

    if source.id == @target.id
      return error_payload("Choose another project as the metadata source.", :unprocessable_entity)
    end

    unless source.project_cell_set_id == pcs_id
      return error_payload(
        "That project does not share the same cell-set identity as this project.",
        :unprocessable_entity
      )
    end

    h = MetadataImportDiscoveryHelpers
    dim = h.dimension_alignment(@target, source)
    annots = eligible_annots_for_source(source, pcs_id)

    payload = {
      target_project: h.project_summary(@target),
      source_project: h.project_summary(source),
      dimensions_aligned: dim[:aligned],
      dimensions_check: dim[:check],
      annots: annots.map { |a| h.annot_import_payload(@target, a, dim) }
    }

    { ok: true, payload: payload }
  end

  private

  def error_payload(message, status)
    { ok: false, error: message, status: status }
  end

  def resolve_source_project
    if @source_project_id.present? && @source_project_id.to_i.positive?
      return Project.find_by(id: @source_project_id.to_i)
    end

    return nil if @source_project_key.blank?

    Project.find_by(key: @source_project_key)
  end

  def eligible_annots_for_source(source, pcs_id)
    Annot.joins(annot_cell_sets: :cell_set)
         .where(project_id: source.id, cell_sets: { project_cell_set_id: pcs_id })
         .where(latest_version: true)
         .where("annots.name LIKE ? OR annots.name LIKE ?", "/col_attrs/%", "/row_attrs/%")
         .includes(:data_type)
         .order("annots.name ASC")
         .distinct
  end
end
