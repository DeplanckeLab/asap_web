# frozen_string_literal: true

# Shared payload and compatibility logic for Mode A / Mode B metadata import discovery (R-M1c).
module MetadataImportDiscoveryHelpers
  module_function

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

  def annot_import_payload(target, annot, dim)
    auth = MetadataNameAuthorizationService.call(project: target, name: annot.name)
    compatible, reason = compatibility_for_annot(target, annot, dim, auth)

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

  def compatibility_for_annot(target, annot, dim, auth)
    return [false, auth.message] unless auth.authorized

    if dim[:check] == "mismatch"
      return [false, "Source project column/row counts differ from the target project."]
    end

    if dim[:check] == "skipped_missing_counts"
      return [true, nil]
    end

    acols = annot.nber_cols
    arows = annot.nber_rows
    if acols.present? && target.nber_cols.present? && acols.to_i != target.nber_cols.to_i
      return [false, "Metadata column count does not match this project."]
    end
    if arows.present? && target.nber_rows.present? && arows.to_i != target.nber_rows.to_i
      return [false, "Metadata row count does not match this project."]
    end

    [true, nil]
  end
end
