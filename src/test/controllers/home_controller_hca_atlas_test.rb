# frozen_string_literal: true

require 'test_helper'

class HomeControllerHcaAtlasTest < ActionDispatch::IntegrationTest
  test 'hca atlas groups unique projects under external catalog collections with entry links' do
    project_id = SecureRandom.uuid
    collection = register_for_test_cleanup(
      ExternalCatalogCollection.upsert_from_catalog!(
        source: 'hca',
        external_key: project_id,
        title: "HCA Atlas Collection #{SecureRandom.hex(3)}",
        description: 'Grouped for atlas hierarchy test',
        source_page_url: "https://data.humancellatlas.org/explore/projects/#{project_id}"
      )
    )

    project = create_test_project!(
      name: "HCA public #{SecureRandom.hex(3)}",
      key: "hca#{SecureRandom.hex(3)}",
      public: true,
      being_deleted: false
    )

    candidate = register_for_test_cleanup(
      ExternalCatalogCandidate.create!(
        source: 'hca',
        external_id: "#{project_id}::#{SecureRandom.uuid}",
        provider_tag: 'HCA',
        title: 'HCA matrix file',
        filename: 'matrix.loom',
        url: 'https://example.com/matrix.loom',
        import_status: 'idle',
        import_project_id: project.id,
        external_catalog_collection_id: collection.id,
        collection_id: project_id,
        tax_id: 9606
      )
    )

    get atlas_projects_path(atlas: 'hca')
    assert_response :success
    assert_match collection.title, response.body
    assert_match project.display_name, response.body
    assert_match 'Catalog entries', response.body
    assert_match candidate.title, response.body
  end
end
