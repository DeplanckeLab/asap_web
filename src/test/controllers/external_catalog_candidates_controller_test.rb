# frozen_string_literal: true

require 'test_helper'

class ExternalCatalogCandidatesControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

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
end
