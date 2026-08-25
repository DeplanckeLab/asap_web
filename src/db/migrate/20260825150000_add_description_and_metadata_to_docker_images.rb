# frozen_string_literal: true

class AddDescriptionAndMetadataToDockerImages < ActiveRecord::Migration[7.2]
  def up
    return unless table_exists?(:docker_images)

    add_column :docker_images, :description, :text unless column_exists?(:docker_images, :description)
    add_column :docker_images, :tool_versions_json, :text unless column_exists?(:docker_images, :tool_versions_json)
    add_column :docker_images, :metadata_json, :text unless column_exists?(:docker_images, :metadata_json)
  end

  def down
    return unless table_exists?(:docker_images)

    remove_column :docker_images, :description if column_exists?(:docker_images, :description)
    remove_column :docker_images, :tool_versions_json if column_exists?(:docker_images, :tool_versions_json)
    remove_column :docker_images, :metadata_json if column_exists?(:docker_images, :metadata_json)
  end
end
