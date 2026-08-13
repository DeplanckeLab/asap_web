# frozen_string_literal: true

require 'test_helper'

class ExternalCatalogCandidateProjectTest < ActiveSupport::TestCase
  test 'link_matched_project records many matches without overwriting import_project_id on content_match' do
    candidate = register_for_test_cleanup(
      ExternalCatalogCandidate.create!(
        source: 'cellxgene',
        external_id: "ds-#{SecureRandom.hex(4)}",
        provider_tag: 'CELLxGENE',
        title: 'Candidate',
        url: 'https://example.com/a.h5ad',
        import_status: 'idle',
        tax_id: 9606
      )
    )
    official = create_test_project!(name: 'Official import', key: "off#{SecureRandom.hex(3)}")
    clone_like = create_test_project!(name: 'User clone', key: "cln#{SecureRandom.hex(3)}")

    candidate.update!(import_project_id: official.id)
    candidate.link_matched_project!(official, link_kind: 'import')
    candidate.link_matched_project!(clone_like, link_kind: 'content_match')

    assert_equal official.id, candidate.reload.import_project_id
    assert_equal 2, candidate.external_catalog_candidate_projects.count
    assert_includes candidate.matched_projects.pluck(:id), official.id
    assert_includes candidate.matched_projects.pluck(:id), clone_like.id
    assert_equal 'import',
                 candidate.external_catalog_candidate_projects.find_by(project_id: official.id).link_kind
    assert_equal 'content_match',
                 candidate.external_catalog_candidate_projects.find_by(project_id: clone_like.id).link_kind
  end

  test 'link_matched_project upgrades existing row to import kind' do
    candidate = register_for_test_cleanup(
      ExternalCatalogCandidate.create!(
        source: 'bgee',
        external_id: "ERP#{SecureRandom.hex(4)}",
        provider_tag: 'Bgee',
        title: 'Bgee cand',
        url: 'https://example.com/b.h5ad',
        import_status: 'idle',
        tax_id: 9606
      )
    )
    project = create_test_project!(name: 'Upgrade kind', key: "upg#{SecureRandom.hex(3)}")

    candidate.link_matched_project!(project, link_kind: 'content_match')
    candidate.link_matched_project!(project, link_kind: 'import')

    assert_equal 1, candidate.external_catalog_candidate_projects.count
    assert_equal 'import', candidate.external_catalog_candidate_projects.first.link_kind
  end

  test 'sync_catalog_links_for_public_project links via provider only when public' do
    provider = Provider.find_or_create_by!(tag: 'CELLxGENE') do |p|
      p.name = 'CELLxGENE'
    end
    external_id = "ds-#{SecureRandom.hex(4)}"
    candidate = register_for_test_cleanup(
      ExternalCatalogCandidate.create!(
        source: 'cellxgene',
        external_id: external_id,
        provider_tag: 'CELLxGENE',
        title: 'CXG cand',
        url: 'https://example.com/c.h5ad',
        import_status: 'idle',
        tax_id: 9606
      )
    )
    pp = ProviderProject.find_or_create_by!(provider_id: provider.id, key: external_id) do |row|
      row.title = 'PP'
    end
    project = create_test_project!(name: 'Provider linked', key: "pub#{SecureRandom.hex(3)}", public: false)
    project.provider_projects << pp unless project.provider_projects.exists?(id: pp.id)

    assert_empty ExternalCatalogCandidate.sync_catalog_links_for_public_project!(project)
    assert_equal 0, candidate.external_catalog_candidate_projects.count

    project.update!(public: true, public_at: Time.current, public_id: (Project.maximum(:public_id) || 0) + 1)
    rows = ExternalCatalogCandidate.sync_catalog_links_for_public_project!(project)
    assert_equal 1, rows.size
    assert_equal 'provider_match', candidate.reload.external_catalog_candidate_projects.find_by!(project_id: project.id).link_kind
  end

  test 'sync_catalog_links_for_public_project links content-match duplicate without provider' do
    sha = Digest::SHA256.hexdigest("bytes-#{SecureRandom.hex(8)}")
    fp = Digest::SHA256.hexdigest({ file_type: 'H5AD' }.to_json)
    official = create_test_project!(
      name: 'Official',
      key: "off#{SecureRandom.hex(3)}",
      public: true,
      public_at: Time.current,
      public_id: (Project.maximum(:public_id) || 0) + 1,
      input_content_sha256: sha,
      input_preparsing_fingerprint: fp
    )
    candidate = register_for_test_cleanup(
      ExternalCatalogCandidate.create!(
        source: 'bgee',
        external_id: "ERP#{SecureRandom.hex(4)}",
        provider_tag: 'Bgee',
        title: 'Official cand',
        url: 'https://example.com/o.h5ad',
        import_status: 'idle',
        tax_id: 9606,
        import_project_id: official.id
      )
    )
    candidate.link_matched_project!(official, link_kind: 'import')

    duplicate = create_test_project!(
      name: 'User ignored warning',
      key: "dup#{SecureRandom.hex(3)}",
      public: true,
      public_at: Time.current,
      public_id: (Project.maximum(:public_id) || 0) + 1,
      input_content_sha256: sha,
      input_preparsing_fingerprint: fp
    )

    rows = ExternalCatalogCandidate.sync_catalog_links_for_public_project!(duplicate)
    assert rows.any?
    assert_equal 'content_match',
                 candidate.reload.external_catalog_candidate_projects.find_by!(project_id: duplicate.id).link_kind
  end
end
