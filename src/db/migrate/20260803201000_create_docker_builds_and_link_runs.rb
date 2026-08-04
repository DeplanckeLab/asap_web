# frozen_string_literal: true

class CreateDockerBuildsAndLinkRuns < ActiveRecord::Migration[7.2]
  RUN_TABLES = %i[runs del_runs active_runs].freeze

  def up
    unless table_exists?(:docker_builds)
      create_table :docker_builds do |t|
        t.references :docker_image, null: false, foreign_key: true, index: true
        t.text :tag, null: false
        t.text :digest, null: false
        t.timestamps null: false
      end
      add_index :docker_builds, :digest, unique: true
    end

    RUN_TABLES.each do |table|
      next unless table_exists?(table)

      unless column_exists?(table, :docker_build_id)
        add_reference table, :docker_build, null: true, foreign_key: true, index: true
      end

      if column_exists?(table, :docker_image_digest)
        remove_column table, :docker_image_digest
      end
    end
  end

  def down
    RUN_TABLES.each do |table|
      next unless table_exists?(table)

      if column_exists?(table, :docker_build_id)
        remove_reference table, :docker_build, foreign_key: true
      end

      unless column_exists?(table, :docker_image_digest)
        add_column table, :docker_image_digest, :text
      end
    end

    drop_table :docker_builds if table_exists?(:docker_builds)
  end
end
