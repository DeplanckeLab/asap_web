# frozen_string_literal: true

require 'json'
require 'rake'
require 'tempfile'
require 'test_helper'
require Rails.root.join('lib/reference_data_steps_std_methods_sync').to_s

# sync_from_dev copies docker_images.runtime_tag: that is how a patch build tested on dev
# is promoted to production (DockerImage.runtime_ref).
class ReferenceDataDockerRuntimeTagSyncTest < ActiveSupport::TestCase
  IMAGE_ID = 9_900_201
  NAME = 'test/asap_run_sync'

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?('reference_data:steps_std_methods:sync_from_dev')
  end

  teardown do
    DockerImage.where(name: NAME).delete_all
  end

  test 'sync copies a changed runtime_tag pin and reports it' do
    DockerImage.create!(id: IMAGE_ID, name: NAME, tag: 'v8', full_name: "#{NAME}:v8", runtime_tag: 'v8.7')
    snapshot = snapshot_file('runtime_tag' => 'v8.8')

    summary = run_sync(snapshot)

    assert_equal 'v8.8', DockerImage.find(IMAGE_ID).runtime_tag
    assert_equal [{ name: NAME, major: 'v8', from: 'v8.7', to: 'v8.8' }],
                 summary[:docker_image_runtime_tag_changes]
  ensure
    snapshot&.close!
  end

  test 'sync leaves the pin alone when dev and prod agree' do
    DockerImage.create!(id: IMAGE_ID, name: NAME, tag: 'v8', full_name: "#{NAME}:v8", runtime_tag: 'v8.7')
    snapshot = snapshot_file('runtime_tag' => 'v8.7')

    summary = run_sync(snapshot)

    assert_equal 'v8.7', DockerImage.find(IMAGE_ID).runtime_tag
    assert_empty summary[:docker_image_runtime_tag_changes]
  ensure
    snapshot&.close!
  end

  test 'compose asap_run follows the pin, not the newest synced DockerBuild' do
    DockerImage.create!(id: IMAGE_ID, name: NAME, tag: 'v8', full_name: "#{NAME}:v8", runtime_tag: 'v8.7')
    saved = ENV['ASAP_DOCKER_NAME']
    ENV['ASAP_DOCKER_NAME'] = NAME

    promoted = {
      docker_image_runtime_tag_changes: [{ name: NAME, major: 'v8', from: 'v8.7', to: 'v8.8' }],
      docker_builds_created_tags: %w[v8.8 v8.9]
    }
    assert_equal 'v8.8', send(:compose_asap_run_tag_after_sync, promoted).first

    built_not_promoted = { docker_image_runtime_tag_changes: [], docker_builds_created_tags: %w[v8.9] }
    assert_nil send(:compose_asap_run_tag_after_sync, built_not_promoted).last
  ensure
    ENV['ASAP_DOCKER_NAME'] = saved
  end

  private

  def run_sync(snapshot)
    ReferenceDataStepsStdMethodsSync.new(snapshot_path: snapshot.path, dry_run: false, max_version_id: 9).run
  end

  def snapshot_file(image_attrs)
    row = {
      'id' => IMAGE_ID, 'name' => NAME, 'tag' => 'v8', 'full_name' => "#{NAME}:v8", 'version' => 8
    }.merge(image_attrs)
    payload = {
      'label' => 'test',
      'records' => {
        'Step' => [], 'StdMethod' => [], 'DockerImage' => [row], 'DockerBuild' => [],
        'Version' => [], 'Speed' => []
      }
    }
    tmp = Tempfile.new(['docker_runtime_tag_sync', '.json'])
    tmp.write(JSON.generate(payload))
    tmp.flush
    tmp
  end
end
