# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

# A guest has one sandbox project: starting another one cancels the catalog import that would replace it.
class ExternalCatalogCandidateGuestCancelTest < ActiveSupport::TestCase
  setup do
    @sandbox_key = "gk#{SecureRandom.hex(3)}"
    @external_id = "gc-#{SecureRandom.hex(4)}"
    @candidate = register_for_test_cleanup(
      ExternalCatalogCandidate.create!(
        source: 'cellxgene',
        external_id: @external_id,
        provider_tag: 'CELLxGENE',
        title: "Guest import #{@external_id}",
        url: "https://example.com/#{@external_id}.h5ad",
        import_status: 'importing',
        import_user_id: User::GUEST_SANDBOX_USER_ID,
        import_resume_json: {
          'job' => true,
          'sandbox_key_digest' => ExternalCatalogCandidate.sandbox_key_digest(@sandbox_key)
        }.to_json,
        tax_id: 9606
      )
    )
  end

  teardown do
    ExternalCatalog::ImportProgress.clear(@candidate.id)
    ExternalCatalog::ImportProgress.clear_cancel(@candidate.id)
  end

  test 'finds the import running for a sandbox key, and only for that key' do
    assert_equal @candidate, ExternalCatalogCandidate.ongoing_import_for_sandbox(@sandbox_key)
    assert_nil ExternalCatalogCandidate.ongoing_import_for_sandbox('another')
    assert_nil ExternalCatalogCandidate.ongoing_import_for_sandbox(nil)

    @candidate.update!(import_status: 'idle')
    assert_nil ExternalCatalogCandidate.ongoing_import_for_sandbox(@sandbox_key)
  end

  test 'with no live job, cancelling frees the candidate at once' do
    assert @candidate.cancel_for_new_sandbox!
    assert_equal 'idle', @candidate.reload.import_status
    assert_nil @candidate.import_error
  end

  test 'a job cancelled while queued ends without importing' do
    ExternalCatalog::ImportProgress.request_cancel!(@candidate.id)

    ExternalCatalogImportCandidateJob.perform_now(@candidate.id, User::GUEST_SANDBOX_USER_ID, sandbox_key: @sandbox_key)

    @candidate.reload
    assert_equal 'idle', @candidate.import_status
    assert_nil @candidate.import_error
    assert_nil @candidate.import_project_id
    assert_not ExternalCatalog::ImportProgress.cancel_requested?(@candidate.id)
  end

  test 'a job failing after a cancellation is reported as cancelled, not failed' do
    ExternalCatalog::ImportProgress.request_cancel!(@candidate.id)
    importer = Object.new
    def importer.import_one(*, **) = raise(ExternalCatalog::ImportProgress::Cancelled, 'Import cancelled')
    def importer.last_import_outcome = nil

    # Let the start-of-job check pass so the run reaches the importer, as a job cancelled mid-download does.
    checks = 0
    ExternalCatalog::ImportProgress.stub(:cancel_requested?, ->(_id) { (checks += 1) > 1 }) do
      ExternalCatalog::ProjectImporter.stub(:new, importer) do
        ExternalCatalogImportCandidateJob.perform_now(@candidate.id, User::GUEST_SANDBOX_USER_ID, sandbox_key: @sandbox_key)
      end
    end

    @candidate.reload
    assert_equal 'idle', @candidate.import_status
    assert_nil @candidate.import_error
  end

  test 'the sandbox is the import result only when created after the run started' do
    @candidate.update!(import_resume_json: @candidate.import_resume.merge('started_at' => 1.minute.ago.iso8601(3)).to_json)
    older = Struct.new(:id, :created_at).new(1, 1.hour.ago)
    newer = Struct.new(:id, :created_at).new(2, Time.current)

    assert_not @candidate.produced_sandbox_project?(nil)
    assert_not @candidate.produced_sandbox_project?(older)
    assert @candidate.produced_sandbox_project?(newer)
  end
end
