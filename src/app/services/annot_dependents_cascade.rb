# frozen_string_literal: true

# Deletes pipeline runs that AnnotDependentsInventory marked as obsolete, then
# optionally destroys the rewritten Annot rows and their loom datasets.
class AnnotDependentsCascade
  class << self
    def call(project:, inventory: nil, inventories: nil, destroy_annots: false, loom_file: nil)
      new(
        project: project,
        inventory: inventory,
        inventories: inventories,
        destroy_annots: destroy_annots,
        loom_file: loom_file
      ).call
    end
  end

  def initialize(project:, inventory: nil, inventories: nil, destroy_annots: false, loom_file: nil)
    @project = project
    @inventories = Array(inventories.presence || inventory).compact
    @destroy_annots = destroy_annots
    @loom_file = loom_file
  end

  def call
    return { ok: true, deleted_run_ids: [], destroyed_annot_ids: [] } if @inventories.empty?

    run_ids = @inventories.flat_map do |inv|
      if inv.respond_to?(:run_ids_to_delete)
        Array(inv.run_ids_to_delete)
      else
        Array(inv[:run_ids_to_delete] || inv["run_ids_to_delete"])
      end
    end.map(&:to_i).uniq.select(&:positive?).sort

    deleted_run_ids = []
    errors = []

    run_ids.each do |run_id|
      run = Run.find_by(id: run_id, project_id: @project.id)
      next unless run

      begin
        RunsController.destroy_run_call(@project, run)
        deleted_run_ids << run_id
      rescue StandardError => e
        unless Run.exists?(run_id)
          deleted_run_ids << run_id
          next
        end
        errors << { run_id: run_id, message: e.message }
        Rails.logger.error("[AnnotDependentsCascade] Failed to delete Run##{run_id}: #{e.class} - #{e.message}")
      end
    end

    destroyed_annot_ids = []
    if @destroy_annots
      annot_ids = @inventories.filter_map do |inv|
        if inv.respond_to?(:annot_id)
          inv.annot_id
        else
          inv[:annot_id] || inv["annot_id"]
        end
      end.map(&:to_i).uniq.select(&:positive?)

      annot_ids.each do |annot_id|
        annot = Annot.find_by(id: annot_id, project_id: @project.id)
        next unless annot

        begin
          delete_loom_dataset_for(annot)
          Cla.where(annot_id: annot.id).delete_all
          AnnotCellSet.where(annot_id: annot.id).delete_all
          annot.destroy!
          destroyed_annot_ids << annot_id
        rescue StandardError => e
          errors << { annot_id: annot_id, message: e.message }
          Rails.logger.error("[AnnotDependentsCascade] Failed to destroy Annot##{annot_id}: #{e.class} - #{e.message}")
        end
      end
    end

    {
      ok: errors.empty?,
      deleted_run_ids: deleted_run_ids.uniq,
      destroyed_annot_ids: destroyed_annot_ids,
      errors: errors
    }
  end

  private

  def delete_loom_dataset_for(annot)
    loom_file = (@loom_file.presence || annot.filepath).to_s
    return if loom_file.blank?

    project_dir = Pathname.new(ENV.fetch("USER_DATA_DIR")) + @project.user_id.to_s + @project.key
    loom_path = project_dir + loom_file
    return unless File.exist?(loom_path)
    return unless H5DataService.metadata_dataset_exists?(loom_path.to_s, annot.name.to_s)

    H5DataService.delete_metadata_dataset!(loom_path.to_s, annot.name.to_s)
  end
end
