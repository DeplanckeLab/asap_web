# frozen_string_literal: true

# Writes a batch-compose multi-category label vector into the loom file and creates
# the matching Annot (sync, same pattern as consensus persist).
class BatchComposeMetadataPersistService
  class << self
    def call(project:, loom_file:, metadata_path:, metadata_basename:, labels:, user_id: nil, provenance: {})
      new(
        project: project,
        loom_file: loom_file,
        metadata_path: metadata_path,
        metadata_basename: metadata_basename,
        labels: labels,
        user_id: user_id,
        provenance: provenance
      ).call
    end
  end

  def initialize(project:, loom_file:, metadata_path:, metadata_basename:, labels:, user_id: nil, provenance: {})
    @project = project
    @loom_file = loom_file.to_s
    @metadata_path = metadata_path.to_s
    @metadata_basename = metadata_basename.to_s
    @labels = Array(labels)
    @user_id = user_id
    @provenance = provenance.is_a?(Hash) ? provenance : {}
  end

  def call
    return error("Metadata path is required.") if @metadata_path.blank?
    return error("Loom file is required.") if @loom_file.blank?
    return error("Batch compose labels are required.") if @labels.empty?

    project_dir = Pathname.new(ENV.fetch("USER_DATA_DIR")) + @project.user_id.to_s + @project.key
    loom_path = project_dir + @loom_file
    return error("Loom file not found on disk: #{@loom_file}") unless File.exist?(loom_path)

    H5DataService.write_metadata_string_vector!(loom_path.to_s, @metadata_path, @labels)

    cats = build_categories(@labels)
    data_type_id = DataType.find_by(name: "DISCRETE")&.id || 3
    attrs_payload = {
      selection_source: "batch_compose",
      batch_mode: true
    }.merge(@provenance).compact

    attrs = {
      name: @metadata_path,
      label: @metadata_basename.presence || @metadata_path.split("/").last,
      filepath: @loom_file,
      dim: 1,
      data_type_id: data_type_id,
      nber_rows: 1,
      nber_cols: @labels.length,
      nber_cats: cats[:nber_cats],
      categories_json: cats[:categories_json],
      list_cat_json: cats[:list_cat_json],
      mem_size: @labels.sum { |label| label.to_s.bytesize },
      imported: true,
      latest_version: true,
      attrs_json: attrs_payload.to_json
    }

    existing = @project.annots.where(name: @metadata_path).order(latest_version: :desc, id: :desc).to_a
    annot = existing.first
    if annot
      extras = existing.drop(1)
      if extras.any?
        extra_ids = extras.map(&:id)
        Cla.where(annot_id: extra_ids).update_all(annot_id: annot.id)
        AnnotCellSet.where(annot_id: extra_ids).update_all(annot_id: annot.id)
        extras.each do |row|
          row.reload
          row.destroy!
        end
      end
      annot.update!(attrs)
    else
      annot = @project.annots.create!(
        attrs.merge(
          version_nber: 1,
          user_id: @user_id || @project.user_id
        )
      )
    end

    if Basic.respond_to?(:ensure_annot_cell_sets)
      Basic.ensure_annot_cell_sets(@project, annot, logger: Rails.logger)
    end

    {
      ok: true,
      annot_id: annot.id,
      metadata_path: @metadata_path,
      metadata_basename: annot.label,
      nber_cats: cats[:nber_cats],
      nber_cols: @labels.length
    }
  rescue StandardError => e
    Rails.logger.error("[BatchComposeMetadataPersistService] #{e.class}: #{e.message}")
    Rails.logger.error(e.backtrace.first(20).join("\n"))
    error(e.message)
  end

  private

  def error(message)
    { ok: false, error: message }
  end

  def build_categories(labels)
    counts = Hash.new(0)
    labels.each { |label| counts[label.to_s] += 1 }
    # Keep blank unassigned out of the displayed category list when possible, but counts stay accurate.
    list_cats = counts.keys.reject { |k| k == "" }.sort
    list_cats << "" if counts.key?("")
    {
      nber_cats: list_cats.size,
      categories_json: counts.to_json,
      list_cat_json: list_cats.to_json
    }
  end
end
