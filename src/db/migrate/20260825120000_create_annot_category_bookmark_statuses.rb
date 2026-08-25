# frozen_string_literal: true

class CreateAnnotCategoryBookmarkStatuses < ActiveRecord::Migration[8.1]
  def change
    create_table :annot_category_bookmark_statuses do |t|
      t.integer :project_id, null: false
      t.integer :annot_id, null: false
      t.integer :cat_idx, null: false
      t.integer :cell_set_id
      t.string :status, null: false, default: 'none'
      t.integer :best_cla_id
      t.integer :markers_run_id
      t.datetime :computed_at

      t.timestamps
    end

    add_index :annot_category_bookmark_statuses, %i[annot_id cat_idx],
              unique: true,
              name: 'idx_annot_cat_bookmark_statuses_annot_cat'
    add_index :annot_category_bookmark_statuses, %i[project_id annot_id],
              name: 'idx_annot_cat_bookmark_statuses_project_annot'
    add_index :annot_category_bookmark_statuses, :cell_set_id,
              name: 'idx_annot_cat_bookmark_statuses_cell_set'
    add_index :annot_category_bookmark_statuses, :status,
              name: 'idx_annot_cat_bookmark_statuses_status'

    add_foreign_key :annot_category_bookmark_statuses, :projects, on_delete: :cascade
    add_foreign_key :annot_category_bookmark_statuses, :annots, on_delete: :cascade
    add_foreign_key :annot_category_bookmark_statuses, :cell_sets, column: :cell_set_id, on_delete: :nullify
    add_foreign_key :annot_category_bookmark_statuses, :clas, column: :best_cla_id, on_delete: :nullify
    add_foreign_key :annot_category_bookmark_statuses, :runs, column: :markers_run_id, on_delete: :nullify
  end
end
