# frozen_string_literal: true

require 'test_helper'

class ExternalCatalogContentDedupTest < ActiveSupport::TestCase
  setup do
    @version = Version.activated.where('id > 3').order(id: :desc).first || Version.order(id: :desc).first
    skip 'No Version available for importer tests' unless @version

    @sc_type = ProjectType.find_by(tag: 'sc') || ProjectType.find_by('name ILIKE ?', '%single%')
    skip 'No single-cell ProjectType' unless @sc_type

    @user = register_for_test_cleanup(
      User.create!(email: "dedup_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )
  end

  test 'link_existing_project attaches provider and merges identifiers onto matching content project' do
    sha = Digest::SHA256.hexdigest("dedup-bytes-#{SecureRandom.hex(8)}")
    fingerprint = Digest::SHA256.hexdigest({ file_type: 'H5AD' }.to_json)
    project = create_test_project!(
      name: 'Existing content project',
      key: "ded#{SecureRandom.hex(3)}",
      user_id: @user.id,
      public: true,
      being_deleted: false,
      input_content_sha256: sha,
      input_preparsing_fingerprint: fingerprint,
      project_type_id: @sc_type.id,
      version_id: @version.id
    )

    entry = ExternalCatalog::Entry.new(
      source: 'bgee',
      external_id: "ERP#{SecureRandom.hex(4)}",
      title: 'Bgee duplicate file',
      url: 'https://example.com/bgee.h5ad',
      tax_id: 9606,
      organism_label: 'Homo sapiens',
      filesize: 10,
      project_type_tag: 'sc',
      format_kind: :h5ad,
      filename: 'bgee.h5ad',
      dois: [],
      pmids: [],
      identifiers: [{ kind: 'sra_study', value: 'ERP013381' }],
      source_page_url: 'https://www.bgee.org/experiment/ERP013381'
    )

    importer = ExternalCatalog::ProjectImporter.new(
      user: @user,
      version: @version,
      skip_archive: true,
      skip_publish: true,
      dry_run: false
    )
    provider = importer.send(:ensure_provider!, entry)

    found = importer.send(:find_live_project_by_content_and_preparsing, sha, fingerprint)
    assert_equal project.id, found.id

    importer.send(:link_existing_project!, project, entry, provider)
    project.reload

    assert project.provider_projects.joins(:provider).where(providers: { tag: 'Bgee' }).exists?
    pp = project.provider_projects.joins(:provider).find_by(providers: { tag: 'Bgee' })
    assert_equal entry.external_id, pp.key
    assert_equal entry.source_page_url, pp.source_page_url
    assert project.exp_entries.where(identifier: 'ERP013381').exists?
  end

  test 'different preparsing fingerprint does not match same content sha' do
    sha = Digest::SHA256.hexdigest("dedup-bytes-#{SecureRandom.hex(8)}")
    fp1 = Digest::SHA256.hexdigest({ 'file_type' => 'H5AD', 'sel_name' => '/raw/X' }.to_json)
    fp2 = Digest::SHA256.hexdigest({ 'file_type' => 'H5AD', 'sel_name' => '/X' }.to_json)
    create_test_project!(
      name: 'Other preparsing',
      key: "prf#{SecureRandom.hex(3)}",
      user_id: @user.id,
      public: true,
      being_deleted: false,
      input_content_sha256: sha,
      input_preparsing_fingerprint: fp1,
      project_type_id: @sc_type.id,
      version_id: @version.id
    )

    importer = ExternalCatalog::ProjectImporter.new(
      user: @user,
      version: @version,
      skip_archive: true,
      skip_publish: true
    )
    assert_nil importer.send(:find_live_project_by_content_and_preparsing, sha, fp2)
  end

  test 'preparsing_fingerprint is stable for equivalent attrs' do
    importer = ExternalCatalog::ProjectImporter.new(
      user: @user,
      version: @version,
      skip_archive: true,
      skip_publish: true
    )
    a = importer.send(:preparsing_fingerprint, { file_type: 'H5AD', sel_name: '/raw/X' })
    b = importer.send(:preparsing_fingerprint, { 'file_type' => 'H5AD', 'sel_name' => '/raw/X' })
    assert_equal a, b
    assert_equal 64, a.length
  end
end
