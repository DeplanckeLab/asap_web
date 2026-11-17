# frozen_string_literal: true

# Patch build (e.g. v8.7) that this instance runs for a major catalog image (v8).
# Dev and prod share one docker daemon and Docker Hub, so the moving :v8 tag cannot differ
# per instance; the pin lives in each database instead. build_asap_run.sh sets it on dev,
# reference_data:steps_std_methods:sync_from_dev copies it to prod (= promotion).
class AddRuntimeTagToDockerImages < ActiveRecord::Migration[7.2]
  def change
    add_column :docker_images, :runtime_tag, :text
  end
end
