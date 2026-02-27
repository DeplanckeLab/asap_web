class AddFinishRunPerformanceIndexes < ActiveRecord::Migration[7.2]
  def up
    unless index_exists?(:annots, [:project_id, :store_run_id, :filepath, :name], name: "idx_annots_finish_run_lookup")
      add_index :annots, [:project_id, :store_run_id, :filepath, :name], name: "idx_annots_finish_run_lookup"
    end

    unless index_exists?(:annots, [:project_id, :name], name: "idx_annots_project_name")
      add_index :annots, [:project_id, :name], name: "idx_annots_project_name"
    end

    unless index_exists?(:clas, :annot_id, name: "idx_clas_annot_id")
      add_index :clas, :annot_id, name: "idx_clas_annot_id"
    end

    unless index_exists?(:annot_cell_sets, :annot_id, name: "idx_annot_cell_sets_annot_id")
      add_index :annot_cell_sets, :annot_id, name: "idx_annot_cell_sets_annot_id"
    end

    unless index_exists?(:ot_projects, [:project_id, :annot_id], name: "idx_ot_projects_project_annot")
      add_index :ot_projects, [:project_id, :annot_id], name: "idx_ot_projects_project_annot"
    end
  end

  def down
    remove_index :ot_projects, name: "idx_ot_projects_project_annot" if index_exists?(:ot_projects, [:project_id, :annot_id], name: "idx_ot_projects_project_annot")
    remove_index :annot_cell_sets, name: "idx_annot_cell_sets_annot_id" if index_exists?(:annot_cell_sets, :annot_id, name: "idx_annot_cell_sets_annot_id")
    remove_index :clas, name: "idx_clas_annot_id" if index_exists?(:clas, :annot_id, name: "idx_clas_annot_id")
    remove_index :annots, name: "idx_annots_project_name" if index_exists?(:annots, [:project_id, :name], name: "idx_annots_project_name")
    remove_index :annots, name: "idx_annots_finish_run_lookup" if index_exists?(:annots, [:project_id, :store_run_id, :filepath, :name], name: "idx_annots_finish_run_lookup")
  end
end
