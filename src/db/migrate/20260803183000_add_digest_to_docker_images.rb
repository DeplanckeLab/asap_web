# frozen_string_literal: true

class AddDigestToDockerImages < ActiveRecord::Migration[7.2]
  def up
    return unless table_exists?(:docker_images)
    return if column_exists?(:docker_images, :digest)

    add_column :docker_images, :digest, :text
  end

  def down
    return unless table_exists?(:docker_images)
    return unless column_exists?(:docker_images, :digest)

    remove_column :docker_images, :digest
  end
end
