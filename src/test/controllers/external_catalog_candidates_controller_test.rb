# frozen_string_literal: true

require 'test_helper'

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

  # Candidate paused after preparsing an H5AD with two matrices and no /raw/X.
  def awaiting_matrix_candidate!(owner)
    external_id = "mtx-#{SecureRandom.hex(4)}"
    candidate = register_for_test_cleanup(
      ExternalCatalogCandidate.create!(
        source: 'cellxgene',
        external_id: external_id,
        provider_tag: 'CELLxGENE',
        title: "Several matrices #{external_id}",
        url: "https://example.com/#{external_id}.h5ad",
        import_status: 'importing',
        import_user_id: owner.id,
        tax_id: 9606
      )
    )
    fu = register_for_test_cleanup(
      Fu.create!(user_id: owner.id, upload_file_name: 'input_file.h5ad', upload_file_size: 0, status: 'preparsed')
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
    candidate.await_matrix_choice!(fu: fu, version_id: 11, skip_archive: true)
    [candidate, fu]
  end

  teardown do
    Array(@matrix_dirs).each { |dir| FileUtils.rm_rf(dir) }
  end

  test 'import_status lists the matrices only for the user who started the import' do
    owner = register_for_test_cleanup(User.create!(email: "ecc_mo_#{SecureRandom.hex(4)}@example.com", password: 'password123'))
    other = register_for_test_cleanup(User.create!(email: "ecc_mx_#{SecureRandom.hex(4)}@example.com", password: 'password123'))
    candidate, = awaiting_matrix_candidate!(owner)

    sign_in other
    get import_status_external_catalog_candidate_path(candidate, format: :json)
    body = JSON.parse(response.body)
    assert_equal 'awaiting_matrix', body['import_status']
    assert_equal false, body['can_choose_matrix']
    assert_nil body['matrix_choices']
    sign_out other

    sign_in owner
    get import_status_external_catalog_candidate_path(candidate, format: :json)
    body = JSON.parse(response.body)
    assert_equal true, body['can_choose_matrix']
    assert_equal %w[/X /layers/raw_count_cellbender], body['matrix_choices'].map { |c| c['path'] }
    assert_equal '/layers/raw_count_cellbender', body['recommended_matrix']
    assert_equal choose_matrix_external_catalog_candidate_path(candidate), body['choose_matrix_url']
  end

  test 'choose_matrix resumes the import with the downloaded file and the chosen matrix' do
    owner = register_for_test_cleanup(User.create!(email: "ecc_mo_#{SecureRandom.hex(4)}@example.com", password: 'password123'))
    candidate, fu = awaiting_matrix_candidate!(owner)

    sign_in owner
    assert_enqueued_with(
      job: ExternalCatalogImportCandidateJob,
      args: [
        candidate.id,
        owner.id,
        { version_id: 11, skip_archive: true, sandbox_key: nil, sel: '/layers/raw_count_cellbender', fu_id: fu.id }
      ]
    ) do
      post choose_matrix_external_catalog_candidate_path(candidate), params: { sel: '/layers/raw_count_cellbender' }
    end
    assert_redirected_to external_catalog_candidate_path(candidate, importing: 1)
    assert_equal 'importing', candidate.reload.import_status
  end

  test 'choose_matrix refuses another user and matrices that are not in the file' do
    owner = register_for_test_cleanup(User.create!(email: "ecc_mo_#{SecureRandom.hex(4)}@example.com", password: 'password123'))
    other = register_for_test_cleanup(User.create!(email: "ecc_mx_#{SecureRandom.hex(4)}@example.com", password: 'password123'))
    candidate, = awaiting_matrix_candidate!(owner)

    sign_in other
    assert_no_enqueued_jobs(only: ExternalCatalogImportCandidateJob) do
      post choose_matrix_external_catalog_candidate_path(candidate), params: { sel: '/X' }
    end
    assert_redirected_to external_catalog_candidate_path(candidate)
    sign_out other

    sign_in owner
    assert_no_enqueued_jobs(only: ExternalCatalogImportCandidateJob) do
      post choose_matrix_external_catalog_candidate_path(candidate), params: { sel: '/layers/../../etc' }
    end
    assert_equal 'awaiting_matrix', candidate.reload.import_status
  end

  test 'cancel_import deletes the download and frees the candidate' do
    owner = register_for_test_cleanup(User.create!(email: "ecc_mo_#{SecureRandom.hex(4)}@example.com", password: 'password123'))
    candidate, fu = awaiting_matrix_candidate!(owner)

    sign_in owner
    post cancel_import_external_catalog_candidate_path(candidate)
    assert_redirected_to external_catalog_candidate_path(candidate)
    assert_equal 'idle', candidate.reload.import_status
    assert_nil Fu.find_by(id: fu.id)
  end
end
