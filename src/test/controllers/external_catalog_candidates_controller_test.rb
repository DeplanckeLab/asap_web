# frozen_string_literal: true

require 'test_helper'
require 'minitest/mock'

class ExternalCatalogCandidatesControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include ActiveJob::TestHelper

  test 'in_asap yes only lists candidates with a project readable by guest' do
    provider = Provider.find_or_create_by!(tag: 'CELLxGENE') do |p|
      p.name = 'CELLxGENE'
    end

    private_ext = "priv-#{SecureRandom.hex(4)}"
    public_ext = "pub-#{SecureRandom.hex(4)}"

    private_candidate = register_for_test_cleanup(
      ExternalCatalogCandidate.create!(
        source: 'cellxgene',
        external_id: private_ext,
        provider_tag: 'CELLxGENE',
        title: "Private only #{private_ext}",
        url: "https://example.com/#{private_ext}.h5ad",
        import_status: 'idle',
        tax_id: 9606,
        n_obs: 10,
        n_vars: 10
      )
    )
    public_candidate = register_for_test_cleanup(
      ExternalCatalogCandidate.create!(
        source: 'cellxgene',
        external_id: public_ext,
        provider_tag: 'CELLxGENE',
        title: "Public linked #{public_ext}",
        url: "https://example.com/#{public_ext}.h5ad",
        import_status: 'idle',
        tax_id: 9606,
        n_obs: 11,
        n_vars: 11
      )
    )

    private_pp = ProviderProject.find_or_create_by!(provider_id: provider.id, key: private_ext) do |row|
      row.title = 'Private PP'
    end
    public_pp = ProviderProject.find_or_create_by!(provider_id: provider.id, key: public_ext) do |row|
      row.title = 'Public PP'
    end

    private_project = create_test_project!(
      name: 'Unreadable private',
      key: "upr#{SecureRandom.hex(3)}",
      public: false
    )
    private_project.provider_projects << private_pp unless private_project.provider_projects.exists?(id: private_pp.id)

    public_project = create_test_project!(
      name: 'Readable public',
      key: "rpb#{SecureRandom.hex(3)}",
      public: true,
      public_at: Time.current,
      public_id: (Project.maximum(:public_id) || 0) + 1
    )
    public_project.provider_projects << public_pp unless public_project.provider_projects.exists?(id: public_pp.id)

    get external_catalog_candidates_path(in_asap: 'yes', q: private_ext)
    assert_response :success
    assert_no_match(/Private only #{Regexp.escape(private_ext)}/, response.body)

    get external_catalog_candidates_path(in_asap: 'yes', q: public_ext)
    assert_response :success
    assert_match(/Public linked #{Regexp.escape(public_ext)}/, response.body)
    assert_match(/#{Regexp.escape(public_project.public_key.presence || public_project.key)}/, response.body)

    get external_catalog_candidates_path(in_asap: 'no', q: private_ext)
    assert_response :success
    assert_match(/Private only #{Regexp.escape(private_ext)}/, response.body)
    assert_match(/Not in ASAP/, response.body)

    assert private_candidate.already_in_asap?
    assert public_candidate.already_in_asap?
  end

  test 'in_asap yes includes own private project for signed-in owner' do
    provider = Provider.find_or_create_by!(tag: 'CELLxGENE') do |p|
      p.name = 'CELLxGENE'
    end
    owner = register_for_test_cleanup(
      User.create!(email: "ecc_own_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )
    external_id = "own-#{SecureRandom.hex(4)}"
    candidate = register_for_test_cleanup(
      ExternalCatalogCandidate.create!(
        source: 'cellxgene',
        external_id: external_id,
        provider_tag: 'CELLxGENE',
        title: "Owned linked #{external_id}",
        url: "https://example.com/#{external_id}.h5ad",
        import_status: 'idle',
        tax_id: 9606,
        n_obs: 12,
        n_vars: 12
      )
    )
    pp = ProviderProject.find_or_create_by!(provider_id: provider.id, key: external_id) do |row|
      row.title = 'Owned PP'
    end
    project = create_test_project!(
      name: 'Owner private',
      key: "ownp#{SecureRandom.hex(3)}",
      public: false,
      user_id: owner.id
    )
    project.provider_projects << pp unless project.provider_projects.exists?(id: pp.id)

    sign_in owner
    get external_catalog_candidates_path(in_asap: 'yes', q: external_id)
    assert_response :success
    assert_match(/Owned linked #{Regexp.escape(external_id)}/, response.body)
    assert_match(/#{Regexp.escape(project.key)}/, response.body)
    assert candidate.already_in_asap?
  end

  # Candidate paused for the project form after downloading and preparsing an H5AD with two matrices.
  def awaiting_form_candidate!(owner_id:, sandbox_key: nil, reason: :matrix, tax_id: 9606)
    external_id = "form-#{SecureRandom.hex(4)}"
    candidate = register_for_test_cleanup(
      ExternalCatalogCandidate.create!(
        source: 'cellxgene',
        external_id: external_id,
        provider_tag: 'CELLxGENE',
        title: "Form import #{external_id}",
        url: "https://example.com/#{external_id}.h5ad",
        import_status: 'importing',
        import_user_id: owner_id,
        tax_id: tax_id
      )
    )
    fu = register_for_test_cleanup(
      Fu.create!(user_id: owner_id, upload_file_name: 'input_file.h5ad', upload_file_size: 10, status: 'preparsed')
    )
    @matrix_dirs = Array(@matrix_dirs) << fu.upload_dir
    FileUtils.mkdir_p(fu.upload_dir)
    File.write(fu.upload_dir.join('input_file.h5ad'), 'h5ad bytes')
    File.write(
      fu.upload_dir.join('output.json'),
      {
        'detected_format' => 'H5AD',
        'list_groups' => [
          { 'group' => '/X', 'nber_rows' => 3, 'nber_cols' => 4, 'is_count' => 0 },
          { 'group' => '/layers/raw_count_cellbender', 'nber_rows' => 3, 'nber_cols' => 4, 'is_count' => 1 }
        ]
      }.to_json
    )
    candidate.await_form_choice!(
      fu: fu, reason: reason, version_id: 11, skip_archive: true, sandbox_key: sandbox_key,
      organism_id: Organism.order(:id).first&.id
    )
    [candidate, fu]
  end

  teardown do
    Array(@matrix_dirs).each { |dir| FileUtils.rm_rf(dir) }
  end

  def new_user(prefix)
    register_for_test_cleanup(User.create!(email: "#{prefix}_#{SecureRandom.hex(4)}@example.com", password: 'password123'))
  end

  test 'import_status sends only the user who started the import to the project form' do
    owner = new_user('ecc_fo')
    other = new_user('ecc_fx')
    candidate, = awaiting_form_candidate!(owner_id: owner.id)

    sign_in other
    get import_status_external_catalog_candidate_path(candidate, format: :json)
    body = JSON.parse(response.body)
    assert_equal 'awaiting_matrix', body['import_status']
    assert_equal 'form', body['choice']
    assert_equal false, body['can_continue']
    assert_nil body['form_url']
    sign_out other

    sign_in owner
    get import_status_external_catalog_candidate_path(candidate, format: :json)
    body = JSON.parse(response.body)
    assert_equal true, body['can_continue']
    assert_equal 'matrix', body['reason']
    assert_equal new_project_path(catalog_import: candidate.id), body['form_url']
    assert_equal candidate.import_resume['awaiting_since'], body['awaiting_since']

    get external_catalog_candidate_path(candidate)
    assert_includes response.body, 'Continue in the project form'
  end

  test 'a pause from before the project form can only be cancelled' do
    owner = new_user('ecc_fo')
    candidate, = awaiting_form_candidate!(owner_id: owner.id)
    candidate.update!(import_resume_json: { 'choice' => 'organism', 'awaiting_since' => Time.current.iso8601 }.to_json)

    sign_in owner
    get import_status_external_catalog_candidate_path(candidate, format: :json)
    body = JSON.parse(response.body)
    assert_equal false, body['can_continue']
    assert_equal cancel_import_external_catalog_candidate_path(candidate), body['cancel_import_url']

    get new_project_path(catalog_import: candidate.id)
    assert_redirected_to external_catalog_candidate_path(candidate)
  end

  test 'cancel_import deletes the download and frees the candidate' do
    owner = new_user('ecc_fo')
    candidate, fu = awaiting_form_candidate!(owner_id: owner.id)

    sign_in owner
    post cancel_import_external_catalog_candidate_path(candidate)
    assert_redirected_to external_catalog_candidate_path(candidate)
    assert_equal 'idle', candidate.reload.import_status
    assert_nil Fu.find_by(id: fu.id)
  end

  test 'the project form opens on the download, prefilled, only for the user who started the import' do
    owner = new_user('ecc_fo')
    other = new_user('ecc_fx')
    candidate, fu = awaiting_form_candidate!(owner_id: owner.id, reason: :text)

    sign_in other
    get new_project_path(catalog_import: candidate.id)
    assert_redirected_to external_catalog_candidate_path(candidate)
    sign_out other

    sign_in owner
    get new_project_path(catalog_import: candidate.id)
    assert_response :success
    body = CGI.unescapeHTML(response.body)
    assert_includes body, %(data-file-upload-existing-fu-id-value="#{fu.id}")
    assert_includes body, %(name="catalog_import_id" id="catalog_import_id" value="#{candidate.id}")
    assert_includes body, 'This is a text matrix: check the delimiter'
    assert_includes body, candidate.to_entry.project_name
    assert_equal fu.id, session[:file_upload]['fu_id'] || session[:file_upload][:fu_id]
  end

  test 'creating the project from the form hands it to the import job' do
    owner = new_user('ecc_fo')
    candidate, fu = awaiting_form_candidate!(owner_id: owner.id)
    organism = Organism.order(:id).first
    ptype = ProjectType.find_by(tag: 'sc')
    skip 'no organism or single-cell type in the test database' unless organism && ptype

    sign_in owner
    get new_project_path(catalog_import: candidate.id)
    assert_response :success

    ProjectInputFinalizerService.stub(:call, nil) do
      post projects_path, params: {
        catalog_import_id: candidate.id,
        file_type: 'H5AD', sel: '/layers/raw_count_cellbender',
        project: { name: 'From the form', organism_id: organism.id, project_type_id: ptype.id }
      }
    end
    project = Project.find_by(name: 'From the form', user_id: owner.id)
    assert project, 'project created'
    register_for_test_cleanup(project)
    assert_redirected_to project_path(project, view: 'analysis')

    assert_enqueued_with(
      job: ExternalCatalogImportCandidateJob,
      args: [candidate.id, owner.id, { version_id: 11, skip_archive: true, sandbox_key: nil, project_id: project.id }]
    )
    candidate.reload
    assert_equal 'importing', candidate.import_status
    assert_equal project.id, candidate.import_project_id
    assert candidate.importing_via_job?
    assert Fu.exists?(fu.id)
  end

  test 'a project form without the import id does not finish the import' do
    owner = new_user('ecc_fo')
    candidate, = awaiting_form_candidate!(owner_id: owner.id)
    organism = Organism.order(:id).first
    ptype = ProjectType.find_by(tag: 'sc')
    skip 'no organism or single-cell type in the test database' unless organism && ptype

    sign_in owner
    get new_project_path(catalog_import: candidate.id)
    ProjectInputFinalizerService.stub(:call, nil) do
      assert_no_enqueued_jobs(only: ExternalCatalogImportCandidateJob) do
        post projects_path, params: {
          file_type: 'H5AD', project: { name: 'Plain upload', organism_id: organism.id, project_type_id: ptype.id }
        }
      end
    end
    register_for_test_cleanup(Project.find_by(name: 'Plain upload', user_id: owner.id))
    assert candidate.reload.awaiting_form?
  end

  test 'a guest continues the import in the form without cancelling it' do
    get new_project_path
    sandbox_key = session[:sandbox]
    skip 'no guest sandbox session' if sandbox_key.blank?

    candidate, fu = awaiting_form_candidate!(owner_id: User::GUEST_SANDBOX_USER_ID, sandbox_key: sandbox_key)
    get new_project_path(catalog_import: candidate.id)
    assert_response :success
    # The form's upload endpoints find a guest's file by its session.
    fu.reload
    assert_nil fu.user_id
    assert_equal sandbox_key, fu.project_key
    assert_includes CGI.unescapeHTML(response.body), 'Creating this project finishes the import of the dataset below'

    # With a sandbox already there, submitting replaces it, but never cancels the import being continued.
    create_test_project!(key: sandbox_key, sandbox: true, user_id: User::GUEST_SANDBOX_USER_ID)
    get new_project_path(catalog_import: candidate.id)
    # The submit button's confirm (the menu's "new sandbox project" link rightly still warns about the import).
    submit_confirm = CGI.unescapeHTML(response.body)[/return confirm\(([^)]*\))/, 1].to_s
    assert_includes submit_confirm, 'Importing this dataset will permanently replace your current sandbox'
    assert_not_includes submit_confirm, 'cancel the import'

    get preparsing_status_fu_path(fu, format: :json)
    assert_response :success

    # Cancelling still deletes the (now session-owned) download.
    post cancel_import_external_catalog_candidate_path(candidate)
    assert_equal 'idle', candidate.reload.import_status
    assert_nil Fu.find_by(id: fu.id)
  end

  def importing_candidate!(owner, resume: { 'job' => true })
    external_id = "imp-#{SecureRandom.hex(4)}"
    register_for_test_cleanup(
      ExternalCatalogCandidate.create!(
        source: 'cellxgene',
        external_id: external_id,
        provider_tag: 'CELLxGENE',
        title: "Importing #{external_id}",
        url: "https://example.com/#{external_id}.h5ad",
        import_status: 'importing',
        import_user_id: owner.id,
        import_resume_json: resume&.to_json,
        tax_id: 9606
      )
    )
  end

  def watch_value
    response.body[/data-catalog-import-watch-value="(\w+)"/, 1]
  end

  test 'show re-opens the import progress for the user who started it, not for others' do
    owner = register_for_test_cleanup(User.create!(email: "ecc_io_#{SecureRandom.hex(4)}@example.com", password: 'password123'))
    other = register_for_test_cleanup(User.create!(email: "ecc_ix_#{SecureRandom.hex(4)}@example.com", password: 'password123'))
    candidate = importing_candidate!(owner)

    sign_in owner
    get external_catalog_candidate_path(candidate)
    assert_response :success
    assert_equal 'true', watch_value
    sign_out owner

    sign_in other
    get external_catalog_candidate_path(candidate)
    assert_response :success
    assert_equal 'false', watch_value
  end

  test 'a web import whose job is gone is reported as failed instead of importing forever' do
    owner = register_for_test_cleanup(User.create!(email: "ecc_id_#{SecureRandom.hex(4)}@example.com", password: 'password123'))
    candidate = importing_candidate!(owner)
    candidate.update_column(:updated_at, 10.minutes.ago)

    sign_in owner
    get import_status_external_catalog_candidate_path(candidate, format: :json)
    body = JSON.parse(response.body)
    assert_equal 'failed', body['import_status']
    assert_match(/stopped unexpectedly/, body['import_error'])
    assert_equal 'failed', candidate.reload.import_status

    # Back on the page after the failure: no overlay, so no alert/reload loop.
    get external_catalog_candidate_path(candidate)
    assert_equal 'false', watch_value
  end

  test 'a recent or rake-driven import is not released for lack of a job' do
    owner = register_for_test_cleanup(User.create!(email: "ecc_ir_#{SecureRandom.hex(4)}@example.com", password: 'password123'))
    fresh = importing_candidate!(owner)
    rake = importing_candidate!(owner, resume: nil)
    rake.update_column(:updated_at, 10.minutes.ago)

    sign_in owner
    [fresh, rake].each do |candidate|
      get import_status_external_catalog_candidate_path(candidate, format: :json)
      assert_equal 'importing', JSON.parse(response.body)['import_status']
      assert_equal 'importing', candidate.reload.import_status
    end
  end

  test 'guests are told that a new sandbox project cancels their running import' do
    get new_project_path
    sandbox_key = session[:sandbox]
    skip 'no guest sandbox session' if sandbox_key.blank?

    candidate = register_for_test_cleanup(
      ExternalCatalogCandidate.create!(
        source: 'cellxgene',
        external_id: "gw-#{SecureRandom.hex(4)}",
        provider_tag: 'CELLxGENE',
        title: 'Running guest import',
        url: 'https://example.com/gw.h5ad',
        import_status: 'importing',
        import_user_id: User::GUEST_SANDBOX_USER_ID,
        import_resume_json: {
          'job' => true,
          'sandbox_key_digest' => ExternalCatalogCandidate.sandbox_key_digest(sandbox_key)
        }.to_json,
        tax_id: 9606
      )
    )

    get new_project_path
    assert_response :success
    body = CGI.unescapeHTML(response.body)
    assert_includes body,
                    'Creating a new sandbox project will cancel the import of "Running guest import", which is still running.'
    # No sandbox project yet: menus and the form point to the import progress page.
    assert_includes body, external_catalog_candidate_path(candidate)
    assert_includes body, 'Import in progress'

    get root_path
    assert_response :success
    assert_includes CGI.unescapeHTML(response.body), 'Importing into your sandbox:'

    candidate.update!(import_status: 'idle')
    get new_project_path
    assert_not_includes CGI.unescapeHTML(response.body), 'Running guest import'
  end

  test 'a row left importing by a rake or old run does not re-open the progress overlay' do
    owner = register_for_test_cleanup(User.create!(email: "ecc_il_#{SecureRandom.hex(4)}@example.com", password: 'password123'))
    candidate = importing_candidate!(owner, resume: nil)

    sign_in owner
    get external_catalog_candidate_path(candidate)
    assert_response :success
    assert_equal 'false', watch_value
  end
end
