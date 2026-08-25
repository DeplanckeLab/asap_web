# frozen_string_literal: true

class RenameAnnotCategoryBookmarkStatusesToAnnotationStatuses < ActiveRecord::Migration[8.1]
  def up
    rename_table :annot_category_bookmark_statuses, :annotation_statuses

    rename_index :annotation_statuses,
                 'idx_annot_cat_bookmark_statuses_annot_cat',
                 'idx_annotation_statuses_annot_cat'
    rename_index :annotation_statuses,
                 'idx_annot_cat_bookmark_statuses_project_annot',
                 'idx_annotation_statuses_project_annot'
    rename_index :annotation_statuses,
                 'idx_annot_cat_bookmark_statuses_cell_set',
                 'idx_annotation_statuses_cell_set'
    rename_index :annotation_statuses,
                 'idx_annot_cat_bookmark_statuses_status',
                 'idx_annotation_statuses_status'
  end

  def down
    rename_index :annotation_statuses,
                 'idx_annotation_statuses_annot_cat',
                 'idx_annot_cat_bookmark_statuses_annot_cat'
    rename_index :annotation_statuses,
                 'idx_annotation_statuses_project_annot',
                 'idx_annot_cat_bookmark_statuses_project_annot'
    rename_index :annotation_statuses,
                 'idx_annotation_statuses_cell_set',
                 'idx_annot_cat_bookmark_statuses_cell_set'
    rename_index :annotation_statuses,
                 'idx_annotation_statuses_status',
                 'idx_annot_cat_bookmark_statuses_status'

    rename_table :annotation_statuses, :annot_category_bookmark_statuses
  end
end
