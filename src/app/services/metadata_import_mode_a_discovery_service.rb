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

    payload = {
      target_project: project_summary(@target),
      cell_set: { id: cell_set.id, key: cell_set.key.to_s },
      sources: sources.map { |source| build_source_entry(source, cell_set) }
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

  def project_summary(project)
    {
      id: project.id,
      key: project.key.to_s,
      name: project.name.to_s,
      public_id: project.public_id,
      nber_cols: project.nber_cols,
      nber_rows: project.nber_rows,
      project_cell_set_id: project.project_cell_set_id
    }
  end

  def build_source_entry(source, cell_set)
    dim = dimension_alignment(@target, source)
    annots = eligible_annots_for_cell_set(source, cell_set)

    {
      project: project_summary(source),
      dimensions_aligned: dim[:aligned],
      dimensions_check: dim[:check],
      annots: annots.map { |a| annot_entry(a, source, dim) }
    }
  end

  def dimension_alignment(target, source)
    tc, tr = target.nber_cols, target.nber_rows
    sc, sr = source.nber_cols, source.nber_rows
    if tc.blank? || tr.blank? || sc.blank? || sr.blank?
      return { aligned: nil, check: "skipped_missing_counts" }
    end

    ok = tc.to_i == sc.to_i && tr.to_i == sr.to_i
    {
      aligned: ok,
      check: ok ? "match" : "mismatch"
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

  def annot_entry(annot, source, dim)
    auth = MetadataNameAuthorizationService.call(project: @target, name: annot.name)

    compatible, reason = compatibility_for_annot(annot, source, dim, auth)

    {
      id: annot.id,
      name: annot.name.to_s,
      display_name: annot.display_name.to_s,
      filepath: annot.filepath.to_s,
      nber_cats: annot.nber_cats,
      nber_cols: annot.nber_cols,
      nber_rows: annot.nber_rows,
      dim: annot.dim,
      import_name_allowed_on_target: auth.authorized,
      import_name_block_reason: auth.authorized ? nil : auth.message,
      compatible: compatible,
      incompatibility_reason: reason
    }
  end

  def compatibility_for_annot(annot, _source, dim, auth)
    return [false, auth.message] unless auth.authorized

    if dim[:check] == "mismatch"
      return [false, "Source project column/row counts differ from the target project."]
    end

    if dim[:check] == "skipped_missing_counts"
      return [true, nil]
    end

    acols = annot.nber_cols
    arows = annot.nber_rows
    if acols.present? && @target.nber_cols.present? && acols.to_i != @target.nber_cols.to_i
      return [false, "Metadata column count does not match this project."]
    end
    if arows.present? && @target.nber_rows.present? && arows.to_i != @target.nber_rows.to_i
      return [false, "Metadata row count does not match this project."]
    end

    [true, nil]
  end
end
