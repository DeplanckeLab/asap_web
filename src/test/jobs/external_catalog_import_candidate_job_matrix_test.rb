# frozen_string_literal: true

require 'test_helper'
require 'minitest/mock'

# Run of a catalog import that paused for the project form, finishing the project created there (project_id).
class ExternalCatalogImportCandidateJobMatrixTest < ActiveSupport::TestCase
  setup do
    @version = Version.activated.where('id > 3').order(id: :desc).first || Version.order(id: :desc).first
    skip 'No Version available for importer tests' unless @version

    @owner = register_for_test_cleanup(
      User.create!(email: "ecj_mx_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )
    @external_id = "mxjob-#{SecureRandom.hex(4)}"
    @candidate = register_for_test_cleanup(
      ExternalCatalogCandidate.create!(
        source: 'cellxgene',
        external_id: @external_id,
        provider_tag: 'CELLxGENE',
        title: "Form import #{@external_id}",
        url: "https://example.com/#{@external_id}.h5ad",
        import_status: 'importing',
        import_user_id: @owner.id,
        tax_id: 9606
      )
    )
    @project = create_test_project!(user_id: @owner.id, public: false)
    @fu = register_for_test_cleanup(
      Fu.create!(user_id: @owner.id, project_id: @project.id, upload_file_name: 'input_file.h5ad',
                 upload_file_size: 0, status: 'preparsed')
    )
  end

  teardown do
    ExternalCatalog::ImportProgress.clear(@candidate.id) if @candidate
  end

  def run_job(importer)
    ExternalCatalog::ProjectImporter.stub(:new, importer) do
      ExternalCatalogImportCandidateJob.perform_now(
        @candidate.id, @owner.id, version_id: @version.id, project_id: @project.id
      )
    end
  end

  test 'a failure while finishing the form project marks the import failed and keeps the project input' do
    fake = Object.new
    fake.define_singleton_method(:complete_form_import) do |*_args, **_kwargs|
      raise ExternalCatalog::ProjectImporter::Error, 'parsing failed'
    end
    fake.define_singleton_method(:import_one) { |*_args, **_kwargs| flunk 'downloaded again' }
    fake.define_singleton_method(:last_import_outcome) { nil }
    fake.define_singleton_method(:last_pipeline_status) { {} }

    ExternalCatalog::ImportSuccessRegistry.stub(:record_import_attempt!, nil) { run_job(fake) }

    @candidate.reload
    assert_equal 'failed', @candidate.import_status
    assert_match(/parsing failed/, @candidate.import_error)
    assert Fu.exists?(@fu.id)
  end

  test 'a form project deleted before the job runs fails the import without importing again' do
    project_id = @project.id
    @fu.update_column(:project_id, nil)
    @project.destroy!
    fake = Object.new
    fake.define_singleton_method(:import_one) { |*_args, **_kwargs| flunk 'downloaded again' }

    ExternalCatalog::ProjectImporter.stub(:new, fake) do
      ExternalCatalogImportCandidateJob.perform_now(@candidate.id, @owner.id, version_id: @version.id, project_id: project_id)
    end

    @candidate.reload
    assert_equal 'failed', @candidate.import_status
    assert_match(/no longer exists/, @candidate.import_error)
  end
end
