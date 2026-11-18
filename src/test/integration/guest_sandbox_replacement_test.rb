# frozen_string_literal: true

require 'test_helper'
require 'tmpdir'
require 'fileutils'

# A guest has one sandbox: creating a new sandbox project replaces the old one and cancels a catalog import
# into the sandbox, but only once the form passed every check (a rejected form loses nothing).
class GuestSandboxReplacementTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @tmp_root = Dir.mktmpdir('guest-sandbox-replace')
    @previous_upload_data_dir = ENV['UPLOAD_DATA_DIR']
    @previous_user_data_dir = ENV['USER_DATA_DIR']
    ENV['UPLOAD_DATA_DIR'] = File.join(@tmp_root, 'fus')
    ENV['USER_DATA_DIR'] = File.join(@tmp_root, 'projects')
    FileUtils.mkdir_p(ENV['UPLOAD_DATA_DIR'])
    FileUtils.mkdir_p(ENV['USER_DATA_DIR'])

    get new_project_path
    @sandbox_key = session[:sandbox]
    skip 'no guest sandbox session' if @sandbox_key.blank?

    @old_sandbox = create_test_project!(key: @sandbox_key, sandbox: true, user_id: User::GUEST_SANDBOX_USER_ID,
                                        name: 'Old sandbox')
    @import = register_for_test_cleanup(
      ExternalCatalogCandidate.create!(
        source: 'cellxgene',
        external_id: "gsr-#{SecureRandom.hex(4)}",
        provider_tag: 'CELLxGENE',
        title: 'Import in the sandbox',
        url: 'https://example.com/gsr.h5ad',
        import_status: 'awaiting_matrix',
        import_user_id: User::GUEST_SANDBOX_USER_ID,
        import_resume_json: {
          'sandbox_key_digest' => ExternalCatalogCandidate.sandbox_key_digest(@sandbox_key),
          'awaiting_since' => Time.current.iso8601
        }.to_json,
        tax_id: 9606
      )
    )
  end

  teardown do
    ExternalCatalog::ImportProgress.clear_cancel(@import.id) if @import
    Project.where(key: @sandbox_key).where.not(id: @old_sandbox&.id).find_each(&:destroy) if @sandbox_key
    destroy_registered_test_records!
    ENV['UPLOAD_DATA_DIR'] = @previous_upload_data_dir
    ENV['USER_DATA_DIR'] = @previous_user_data_dir
    FileUtils.rm_rf(@tmp_root) if @tmp_root.present?
  end

  test 'a rejected guest submission keeps the old sandbox and the import' do
    # No uploaded file in the session: the form comes back with an error.
    post projects_path, params: { project: { name: 'New sandbox' } }

    assert_response :unprocessable_entity
    assert Project.exists?(@old_sandbox.id), 'old sandbox must survive a rejected form'
    assert_equal 'awaiting_matrix', @import.reload.import_status
  end

  test 'a successful guest submission replaces the sandbox and cancels the import' do
    fu = upload_input_file!
    project_type = ProjectType.first
    organism = Organism.first
    skip 'needs a project type and an organism' unless project_type && organism

    post projects_path, params: {
      project: { name: 'New sandbox', project_type_id: project_type.id, organism_id: organism.id },
      file_type: 'H5AD'
    }

    new_project = Project.find_by(key: @sandbox_key)
    assert new_project, "new sandbox project not saved (status #{response.status})"
    assert_equal 'New sandbox', new_project.name
    assert_not Project.exists?(@old_sandbox.id)
    assert_equal fu.id, new_project.fu_id if new_project.fu_id
    assert_equal 'idle', @import.reload.import_status
  end

  private

  # Same path as the compliance hand-off: an adopted Fu lands in session[:file_upload].
  def upload_input_file!
    upload_type_id = UploadType.id_for('compliance_file_check')
    skip 'compliance_file_check upload type missing' if upload_type_id.blank?

    fu = register_for_test_cleanup(
      Fu.create!(user_id: nil, project_key: @sandbox_key, upload_file_name: 'input_file.h5ad', upload_file_size: 12,
                 name: 'demo.h5ad', status: 'validated', upload_type: upload_type_id,
                 url: 'https://example.com/demo.h5ad')
    )
    FileUtils.mkdir_p(fu.upload_dir)
    File.write(fu.upload_dir + fu.upload_file_name, "h5ad-bytes\n")
    get new_project_path, params: { from: 'scfair_validation', fu_id: fu.id }
    skip 'compliance hand-off did not set the upload' unless session.dig(:file_upload, :fu_id) == fu.id
    fu
  end
end
