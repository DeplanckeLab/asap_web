# frozen_string_literal: true

require 'test_helper'

class ExternalCatalogImportProgressTest < ActiveSupport::TestCase
  setup do
    @candidate_id = 42_001
    ExternalCatalog::ImportProgress.clear(@candidate_id)
  end

  teardown do
    ExternalCatalog::ImportProgress.clear(@candidate_id)
  end

  test 'report tracks completed steps across transitions' do
    ExternalCatalog::ImportProgress.report(@candidate_id, step: 'queued')
    ExternalCatalog::ImportProgress.report(@candidate_id, step: 'downloading')
    ExternalCatalog::ImportProgress.report(@candidate_id, step: 'preparsing')
    payload = ExternalCatalog::ImportProgress.report(@candidate_id, step: 'creating_project')

    assert_equal 'creating_project', payload['step']
    assert_includes payload['steps_completed'], 'queued'
    assert_includes payload['steps_completed'], 'downloading'
    assert_includes payload['steps_completed'], 'preparsing'
    refute_includes payload['steps_completed'], 'linking_project'
  end

  test 'linking path does not keep creating_project as completed' do
    ExternalCatalog::ImportProgress.report(@candidate_id, step: 'preparsing')
    ExternalCatalog::ImportProgress.report(@candidate_id, step: 'linking_project')
    payload = ExternalCatalog::ImportProgress.report(@candidate_id, step: 'opening')

    assert_includes payload['steps_completed'], 'linking_project'
    refute_includes payload['steps_completed'], 'creating_project'
  end

  test 'report_download sets transfer fields' do
    payload = ExternalCatalog::ImportProgress.report_download(
      @candidate_id,
      downloaded: 50,
      total: 200
    )

    assert_equal 'downloading', payload['step']
    assert_equal 25, payload['transfer_progress']
    assert_equal 50, payload['transfer_downloaded']
    assert_equal 200, payload['transfer_total']
  end
end
