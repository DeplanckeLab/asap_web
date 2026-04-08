# frozen_string_literal: true

class AddRootProjectIdToProjects < ActiveRecord::Migration[7.0]
  def up
    add_column :projects, :root_project_id, :integer unless column_exists?(:projects, :root_project_id)

    unless index_exists?(:projects, :root_project_id)
      add_index :projects, :root_project_id
    end

    unless foreign_key_exists?(:projects, column: :root_project_id)
      add_foreign_key :projects, :projects, column: :root_project_id, primary_key: :id, on_delete: :nullify
    end

    backfill_root_project_ids
  end

  def down
    if foreign_key_exists?(:projects, column: :root_project_id)
      remove_foreign_key :projects, column: :root_project_id
    end
    remove_index :projects, :root_project_id if index_exists?(:projects, :root_project_id)
    remove_column :projects, :root_project_id if column_exists?(:projects, :root_project_id)
  end

  private

  def backfill_root_project_ids
    return unless column_exists?(:projects, :root_project_id)

    Project.where.not(cloned_project_id: nil).where(root_project_id: nil).find_each do |project|
      root_id = compute_root_project_id(project)
      project.update_column(:root_project_id, root_id) if root_id
    end
  end

  def compute_root_project_id(project)
    cur = project
    seen = {}
    while cur.cloned_project_id.present?
      return nil if seen[cur.id]
      seen[cur.id] = true
      parent = Project.find_by(id: cur.cloned_project_id)
      return nil unless parent
      cur = parent
    end
    cur.id
  end
end
