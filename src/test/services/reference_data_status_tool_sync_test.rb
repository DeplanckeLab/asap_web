# frozen_string_literal: true

require 'json'
require 'tempfile'
require 'test_helper'
require Rails.root.join('lib/reference_data_steps_std_methods_sync').to_s

class ReferenceDataStatusToolSyncTest < ActiveSupport::TestCase
  STATUS_ID = 9_900_101
  TOOL_TYPE_ID = 9_900_102
  TOOL_ID = 9_900_103

  teardown do
    Tool.where(id: TOOL_ID).delete_all
    ToolType.where(id: TOOL_TYPE_ID).delete_all
    Status.where(id: STATUS_ID).delete_all
  end

  test 'sync creates Status by id from snapshot' do
    snapshot = snapshot_file(
      statuses: [
        {
          'id' => STATUS_ID,
          'name' => 'sync_pending',
          'label' => 'default',
          'display_label' => 'Sync Pending',
          'badge_bg_class' => 'bg-yellow-100',
          'badge_text_class' => 'text-yellow-800'
        }
      ]
    )

    summary = ReferenceDataStepsStdMethodsSync.new(
      snapshot_path: snapshot.path,
      dry_run: false,
      max_version_id: 9
    ).run

    record = Status.find_by(id: STATUS_ID)
    assert_equal 1, summary[:statuses_created]
    assert_equal 'sync_pending', record.name
    assert_equal 'Sync Pending', record.display_label
  ensure
    snapshot&.close!
  end

  test 'sync updates Status badge classes by id' do
    Status.create!(
      id: STATUS_ID,
      name: 'sync_pending',
      label: 'default',
      display_label: 'Sync Pending',
      badge_bg_class: 'bg-gray-100',
      badge_text_class: 'text-gray-800'
    )
    snapshot = snapshot_file(
      statuses: [
        {
          'id' => STATUS_ID,
          'name' => 'sync_pending',
          'label' => 'default',
          'display_label' => 'Sync Pending',
          'badge_bg_class' => 'bg-yellow-100',
          'badge_text_class' => 'text-yellow-800'
        }
      ]
    )

    summary = ReferenceDataStepsStdMethodsSync.new(
      snapshot_path: snapshot.path,
      dry_run: false,
      max_version_id: 9
    ).run

    assert_equal 1, summary[:statuses_updated]
    assert_equal 'bg-yellow-100', Status.find(STATUS_ID).badge_bg_class
  ensure
    snapshot&.close!
  end

  test 'sync creates ToolType then Tool by id from snapshot' do
    snapshot = snapshot_file(
      tool_types: [
        {
          'id' => TOOL_TYPE_ID,
          'name' => 'SyncLang'
        }
      ],
      tools: [
        {
          'id' => TOOL_ID,
          'name' => 'scanpy_sync_test',
          'label' => 'Scanpy',
          'package' => 'scanpy',
          'tool_type_id' => TOOL_TYPE_ID,
          'title' => 'Single-Cell Analysis in Python',
          'url' => 'https://scanpy.readthedocs.io/',
          'description' => 'Toolkit for single-cell analysis.',
          'step_ids' => ''
        }
      ]
    )

    summary = ReferenceDataStepsStdMethodsSync.new(
      snapshot_path: snapshot.path,
      dry_run: false,
      max_version_id: 9
    ).run

    tool_type = ToolType.find_by(id: TOOL_TYPE_ID)
    tool = Tool.find_by(id: TOOL_ID)
    assert_equal 1, summary[:tool_types_created]
    assert_equal 1, summary[:tools_created]
    assert_equal 'SyncLang', tool_type.name
    assert_equal 'scanpy_sync_test', tool.name
    assert_equal 'scanpy', tool.package
    assert_equal TOOL_TYPE_ID, tool.tool_type_id
  ensure
    snapshot&.close!
  end

  test 'sync updates Tool description by id' do
    ToolType.create!(id: TOOL_TYPE_ID, name: 'SyncLang')
    Tool.create!(
      id: TOOL_ID,
      name: 'scanpy_sync_test',
      label: 'Scanpy',
      package: 'scanpy',
      tool_type_id: TOOL_TYPE_ID,
      title: 'Single-Cell Analysis in Python',
      description: 'old description',
      step_ids: ''
    )
    snapshot = snapshot_file(
      tool_types: [
        {
          'id' => TOOL_TYPE_ID,
          'name' => 'SyncLang'
        }
      ],
      tools: [
        {
          'id' => TOOL_ID,
          'name' => 'scanpy_sync_test',
          'label' => 'Scanpy',
          'package' => 'scanpy',
          'tool_type_id' => TOOL_TYPE_ID,
          'title' => 'Single-Cell Analysis in Python',
          'description' => 'updated description',
          'step_ids' => ''
        }
      ]
    )

    summary = ReferenceDataStepsStdMethodsSync.new(
      snapshot_path: snapshot.path,
      dry_run: false,
      max_version_id: 9
    ).run

    assert_equal 1, summary[:tools_updated]
    assert_equal 'updated description', Tool.find(TOOL_ID).description
  ensure
    snapshot&.close!
  end

  def snapshot_file(statuses: nil, tool_types: nil, tools: nil)
    records = {
      'Step' => [],
      'StdMethod' => [],
      'DockerImage' => [],
      'DockerBuild' => [],
      'Version' => [],
      'Speed' => []
    }
    records['Status'] = statuses if statuses
    records['ToolType'] = tool_types if tool_types
    records['Tool'] = tools if tools

    payload = {
      'label' => 'test',
      'records' => records
    }
    tmp = Tempfile.new(['status_tool_sync', '.json'])
    tmp.write(JSON.generate(payload))
    tmp.flush
    tmp
  end
end
