# frozen_string_literal: true

require 'test_helper'
require 'minitest/mock'

# Second run of a catalog import paused for an H5AD matrix choice (sel + fu_id).
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
        title: "Resumed import #{@external_id}",
        url: "https://example.com/#{@external_id}.h5ad",
        import_status: 'importing',
        import_user_id: @owner.id,
        tax_id: 9606
      )
    )
    @fu = register_for_test_cleanup(
      Fu.create!(user_id: @owner.id, upload_file_name: 'input_file.h5ad', upload_file_size: 0, status: 'preparsed')
    )
    @dir = @fu.upload_dir
    FileUtils.mkdir_p(@dir)
    File.write(@dir.join('input_file.h5ad'), 'h5ad bytes')
    File.write(
      @dir.join('output.json'),
      {
        'detected_format' => 'H5AD',
        'list_groups' => [
          { 'group' => '/X', 'nber_rows' => 3, 'nber_cols' => 4, 'is_count' => 0 },
          { 'group' => '/layers/counts', 'nber_rows' => 3, 'nber_cols' => 4, 'is_count' => 1 }
        ]
      }.to_json
    )
    @candidate.await_matrix_choice!(fu: @fu, version_id: @version.id, skip_archive: true)
  end

  teardown do
    FileUtils.rm_rf(@dir) if @dir
    ExternalCatalog::ImportProgress.clear(@candidate.id) if @candidate
  end

  test 'a resumed run that finds the dataset already in ASAP deletes the download' do
    # The owner got the dataset another way while the choice was pending.
    provider = Provider.find_or_create_by!(tag: 'CELLxGENE') { |p| p.name = 'CELLxGENE' }
    pp = ProviderProject.find_or_create_by!(provider_id: provider.id, key: @external_id) { |row| row.title = 'PP' }
    project = create_test_project!(user_id: @owner.id, public: false)
    project.provider_projects << pp
    # Teardown destroys in reverse order: candidate (and its project links), then the project, then its owner.
    @records_for_test_cleanup.delete(project)
    @records_for_test_cleanup.insert(@records_for_test_cleanup.index(@owner) + 1, project)

    # record_import_attempt! appends to the import-success TSV under DATA_DIR: keep tests out of it.
    ExternalCatalog::ImportSuccessRegistry.stub(:record_import_attempt!, nil) do
      ExternalCatalogImportCandidateJob.perform_now(
        @candidate.id, @owner.id,
        version_id: @version.id, skip_archive: true, sel: '/layers/counts', fu_id: @fu.id
      )
    end

    @candidate.reload
    assert_equal 'idle', @candidate.import_status
    assert_nil @candidate.import_resume_json
    assert_nil Fu.find_by(id: @fu.id)
    refute File.exist?(@dir)
  end

  test 'a resumed run that fails before creating a project deletes the download' do
    # The Version picked at pause time was removed in the meantime.
    ExternalCatalogImportCandidateJob.perform_now(
      @candidate.id, @owner.id,
      version_id: -1, skip_archive: true, sel: '/layers/counts', fu_id: @fu.id
    )

    @candidate.reload
    assert_equal 'failed', @candidate.import_status
    assert_nil @candidate.import_resume_json
    assert_nil Fu.find_by(id: @fu.id)
  end
end
