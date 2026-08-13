# frozen_string_literal: true

require 'test_helper'

class ProjectCollectionTest < ActiveSupport::TestCase
  test 'upsert_from_catalog creates by source and external_key' do
    collection = register_for_test_cleanup(
      ProjectCollection.upsert_from_catalog!(
        source: 'cellxgene',
        external_key: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
        title: 'Tabula Example',
        description: 'An example atlas collection',
        source_page_url: 'https://cellxgene.cziscience.com/collections/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
      )
    )

    assert_equal 'cellxgene', collection.source
    assert_equal 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee', collection.external_key
    assert_equal 'Tabula Example', collection.title
    assert_equal 'An example atlas collection', collection.description
  end

  test 'upsert_from_catalog reuses identity and preserves existing title' do
    external_key = "coll-#{SecureRandom.hex(8)}"
    first = register_for_test_cleanup(
      ProjectCollection.upsert_from_catalog!(
        source: 'cellxgene',
        external_key: external_key,
        title: 'Custom title',
        description: 'Kept description'
      )
    )

    second = ProjectCollection.upsert_from_catalog!(
      source: 'cellxgene',
      external_key: external_key,
      title: 'Upstream title',
      description: 'Upstream description'
    )

    assert_equal first.id, second.id
    assert_equal 'Custom title', second.reload.title
    assert_equal 'Kept description', second.description
  end

  test 'project belongs to at most one collection' do
    collection_a = register_for_test_cleanup(
      ProjectCollection.create_manual!(title: "Collection A #{SecureRandom.hex(3)}")
    )
    collection_b = register_for_test_cleanup(
      ProjectCollection.create_manual!(title: "Collection B #{SecureRandom.hex(3)}")
    )
    project = create_test_project!(
      name: 'Membership project',
      key: "mpc#{SecureRandom.hex(3)}",
      project_collection_id: collection_a.id
    )

    assert_equal collection_a.id, project.project_collection_id

    project.update!(project_collection_id: collection_b.id)
    assert_equal collection_b.id, project.reload.project_collection_id
    assert_includes collection_b.projects, project
    assert_not_includes collection_a.projects.reload, project
  end

  test 'create_manual leaves external_key blank' do
    collection = register_for_test_cleanup(
      ProjectCollection.create_manual!(title: "Manual #{SecureRandom.hex(3)}", description: 'User created')
    )

    assert_equal 'manual', collection.source
    assert_nil collection.external_key
    assert_equal 'User created', collection.description
  end
end
