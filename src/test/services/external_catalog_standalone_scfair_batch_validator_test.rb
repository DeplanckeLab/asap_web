# frozen_string_literal: true

require_relative '../services/test_base_without_fixtures'

class ExternalCatalogStandaloneScfairBatchValidatorTest < TestBaseWithoutFixtures
  include ActiveJob::TestHelper
  test 'dry_run queues loom/h5ad SC candidates and skips unsupported formats' do
    upload_type_id = UploadType.id_for('compliance_file_check')
    skip 'compliance_file_check upload type missing' if upload_type_id.blank?

    register_for_test_cleanup(
      ExternalCatalogCandidate.create!(
        source: 'cellxgene',
        external_id: "batch-sc-#{SecureRandom.hex(4)}",
        provider_tag: 'cxg',
        title: 'SC h5ad',
        url: "https://example.com/sc-#{SecureRandom.hex(4)}.h5ad",
        filename: 'sc.h5ad',
        format_kind: 'h5ad',
        project_type_tag: 'sc',
        filesize: 100,
        obsolete: false
      )
    )
    register_for_test_cleanup(
      ExternalCatalogCandidate.create!(
        source: 'geo',
        external_id: "batch-mtx-#{SecureRandom.hex(4)}",
        provider_tag: 'geo',
        title: 'SC mtx',
        url: "https://example.com/matrix-#{SecureRandom.hex(4)}.tar.gz",
        filename: 'matrix.tar.gz',
        format_kind: 'mtx',
        project_type_tag: 'sc',
        filesize: 100,
        obsolete: false
      )
    )

    result = ExternalCatalog::StandaloneScfairBatchValidator.new(
      source: 'all',
      dry_run: true,
      skip_existing: false
    ).call

    assert_operator result.queued, :>=, 1
    assert_operator result.skipped_unsupported, :>=, 1
  end

  test 'enqueue creates Fu with admin_run and queues download job' do
    upload_type_id = UploadType.id_for('compliance_file_check')
    skip 'compliance_file_check upload type missing' if upload_type_id.blank?

    candidate = register_for_test_cleanup(
      ExternalCatalogCandidate.create!(
        source: 'bgee',
        external_id: "batch-enq-#{SecureRandom.hex(4)}",
        provider_tag: 'bgee',
        title: 'Enqueue me',
        url: "https://example.com/enq-#{SecureRandom.hex(4)}.h5ad",
        filename: 'enq.h5ad',
        format_kind: 'h5ad',
        project_type_tag: 'sc',
        filesize: 50,
        obsolete: false
      )
    )

    assert_enqueued_with(job: IsolatedComplianceUrlDownloadJob) do
      result = ExternalCatalog::StandaloneScfairBatchValidator.new(
        candidate_ids: [candidate.id],
        dry_run: false,
        skip_existing: true
      ).call
      assert_equal 1, result.queued
    end

    fu = Fu.where(url: candidate.url, admin_run: true).order(id: :desc).first
    assert fu, 'Expected Fu for candidate URL'
    register_for_test_cleanup(fu)
    assert_equal true, fu.admin_run
    assert_nil fu.creator_ip
    assert_equal 'downloading', fu.status
  end

  test 'skip_existing ignores URLs already validated as admin_run' do
    upload_type_id = UploadType.id_for('compliance_file_check')
    skip 'compliance_file_check upload type missing' if upload_type_id.blank?

    url = "https://example.com/existing-#{SecureRandom.hex(4)}.h5ad"
    register_for_test_cleanup(
      ExternalCatalogCandidate.create!(
        source: 'ebi_sc',
        external_id: "batch-exist-#{SecureRandom.hex(4)}",
        provider_tag: 'ebi_sc',
        title: 'Already checked',
        url: url,
        filename: 'existing.h5ad',
        format_kind: 'h5ad',
        project_type_tag: 'sc',
        filesize: 10,
        obsolete: false
      )
    )
    register_for_test_cleanup(
      StandaloneComplianceCheck.create!(
        task_id: SecureRandom.uuid,
        filename: 'existing.h5ad',
        source_url: url,
        format: 'h5ad',
        schema_id: 'scfair_7_1_0',
        passed: false,
        status: 'completed',
        checked_at: Time.current,
        result_json: { 'valid' => false },
        admin_run: true
      )
    )

    result = ExternalCatalog::StandaloneScfairBatchValidator.new(
      source: 'ebi_sc',
      dry_run: true,
      skip_existing: true
    ).call

    assert_operator result.skipped_existing, :>=, 1
  end
end
