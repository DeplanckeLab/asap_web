# frozen_string_literal: true

class CreateProjectOrigins < ActiveRecord::Migration[7.1]
  class ProjectOrigin < ActiveRecord::Base
    self.table_name = 'project_origins'
  end

  ORIGINS = [
    [1, 'upload', 'Upload'],
    [2, 'clone', 'Clone'],
    [3, 'integration', 'Integration'],
    [4, 'scfair_validation', 'scFAIR validation']
  ].freeze

  def up
    create_table :project_origins do |t|
      t.text :name, null: false
      t.text :label
      t.timestamps
    end
    add_index :project_origins, :name, unique: true

    now = Time.current
    ORIGINS.each do |id, name, label|
      ensure_origin!(id, name, label, now)
    end

    upload_id = ProjectOrigin.find_by!(name: 'upload').id
    add_column :projects, :project_origin_id, :integer, null: false, default: upload_id
    add_foreign_key :projects, :project_origins
    add_index :projects, :project_origin_id

    # Existing clones / integrations: refine default beyond upload where detectable.
    clone_id = ProjectOrigin.find_by!(name: 'clone').id
    integration_id = ProjectOrigin.find_by!(name: 'integration').id

    execute <<-SQL.squish
      UPDATE projects
      SET project_origin_id = #{clone_id}
      WHERE cloned_project_id IS NOT NULL
    SQL

    execute <<-SQL.squish
      UPDATE projects
      SET project_origin_id = #{integration_id}
      WHERE cloned_project_id IS NULL
        AND parsing_attrs_json IS NOT NULL
        AND parsing_attrs_json <> ''
        AND parsing_attrs_json ~ '^\\s*\\{'
        AND (
          parsing_attrs_json::jsonb ? 'integrate_method'
          OR parsing_attrs_json::jsonb ? 'integrate_batch_paths'
        )
    SQL
  end

  def down
    remove_foreign_key :projects, :project_origins
    remove_index :projects, :project_origin_id
    remove_column :projects, :project_origin_id
    drop_table :project_origins
  end

  def ensure_origin!(id, name, label, now)
    by_id = ProjectOrigin.find_by(id: id)
    by_name = ProjectOrigin.find_by(name: name)

    return if by_id && by_id.name == name

    by_name&.delete if by_name && by_name.id != id
    by_id&.delete if by_id && by_id.name != name

    ProjectOrigin.create!(id: id, name: name, label: label, created_at: now, updated_at: now)
  end
end
