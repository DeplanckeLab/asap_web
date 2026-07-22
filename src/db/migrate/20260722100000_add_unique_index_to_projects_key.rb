class AddUniqueIndexToProjectsKey < ActiveRecord::Migration[7.2]
  class MigrationProject < ApplicationRecord
    self.table_name = "projects"
  end

  def up
    deduplicate_project_keys!

    add_index :projects,
              :key,
              unique: true,
              name: "index_projects_on_key_unique",
              where: "key IS NOT NULL AND key <> ''"
  end

  def down
    remove_index :projects, name: "index_projects_on_key_unique"
  end

  private

  def deduplicate_project_keys!
    duplicate_keys = MigrationProject
      .where.not(key: [nil, ""])
      .group(:key)
      .having("COUNT(*) > 1")
      .pluck(:key)

    duplicate_keys.each do |key|
      MigrationProject.where(key: key).order(:id).offset(1).find_each do |project|
        project.update_column(:key, generate_unique_key)
      end
    end
  end

  def generate_unique_key
    loop do
      key = Array.new(6) { [*"0".."9", *"a".."z"].sample }.join
      return key unless MigrationProject.exists?(key: key)
    end
  end
end
