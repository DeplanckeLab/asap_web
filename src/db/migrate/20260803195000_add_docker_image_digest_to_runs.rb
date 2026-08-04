# frozen_string_literal: true

class AddDockerImageDigestToRuns < ActiveRecord::Migration[7.2]
  TABLES = %i[runs del_runs active_runs].freeze

  def up
    TABLES.each do |table|
      next unless table_exists?(table)
      next if column_exists?(table, :docker_image_digest)

      add_column table, :docker_image_digest, :text
    end
  end

  def down
    TABLES.each do |table|
      next unless table_exists?(table)
      next unless column_exists?(table, :docker_image_digest)

      remove_column table, :docker_image_digest
    end
  end
end
