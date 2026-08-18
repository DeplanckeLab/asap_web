# frozen_string_literal: true

require 'json'
require 'tempfile'
require 'test_helper'
require Rails.root.join('lib/reference_data_steps_std_methods_sync').to_s

class ReferenceDataComplianceSchemaSyncTest < ActiveSupport::TestCase
  SYNC_ID = 9_900_001

  teardown do
    ComplianceSchema.where(id: SYNC_ID).delete_all
  end

  test 'sync creates ComplianceSchema by id from snapshot' do
    snapshot = snapshot_file(
      [
        {
          'id' => SYNC_ID,
          'name' => 'scFAIR sync test',
          'version' => '7.1.0',
          'project_type_tags' => 'sc,spat,atac,multi',
          'if_compliant' => 'allow_public',
          'active' => true,
          'source_schema_name' => 'scFAIR schema'
        }
      ]
    )

    summary = ReferenceDataStepsStdMethodsSync.new(
      snapshot_path: snapshot.path,
      dry_run: false,
      max_version_id: 9
    ).run

    record = ComplianceSchema.find_by(id: SYNC_ID)
    assert_equal 1, summary[:compliance_schemas_created]
    assert_equal 'scFAIR sync test', record.name
    assert_equal 'sc,spat,atac,multi', record.project_type_tags
  ensure
    snapshot&.close!
  end

  test 'sync updates ComplianceSchema project_type_tags by id' do
    ComplianceSchema.create!(
      id: SYNC_ID,
      name: 'scFAIR sync test',
      version: '7.1.0',
      project_type_tags: 'sc',
      if_compliant: 'allow_public',
      active: true
    )
    snapshot = snapshot_file(
      [
        {
          'id' => SYNC_ID,
          'name' => 'scFAIR sync test',
          'version' => '7.1.0',
          'project_type_tags' => 'sc,spat,atac,multi',
          'if_compliant' => 'allow_public',
          'active' => true
        }
      ]
    )

    summary = ReferenceDataStepsStdMethodsSync.new(
      snapshot_path: snapshot.path,
      dry_run: false,
      max_version_id: 9
    ).run

    assert_equal 1, summary[:compliance_schemas_updated]
    assert_equal 'sc,spat,atac,multi', ComplianceSchema.find(SYNC_ID).project_type_tags
  ensure
    snapshot&.close!
  end

  def snapshot_file(compliance_schemas)
    payload = {
      'label' => 'test',
      'records' => {
        'Step' => [],
        'StdMethod' => [],
        'DockerImage' => [],
        'DockerBuild' => [],
        'Version' => [],
        'Speed' => [],
        'ComplianceSchema' => compliance_schemas
      }
    }
    tmp = Tempfile.new(['compliance_schema_sync', '.json'])
    tmp.write(JSON.generate(payload))
    tmp.flush
    tmp
  end
end
