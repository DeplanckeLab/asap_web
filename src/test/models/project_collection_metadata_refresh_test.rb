# frozen_string_literal: true

require 'test_helper'

class ExternalCatalogCollectionMetadataRefreshTest < ActiveSupport::TestCase
  test 'upsert_from_catalog refreshes placeholder titles and blank descriptions' do
    key = SecureRandom.uuid
    placeholder = ProjectCollection.placeholder_title_for('cellxgene', key)
    pc = register_for_test_cleanup(
      ProjectCollection.create!(
        source: 'cellxgene',
        external_key: key,
        title: placeholder,
        description: nil
      )
    )

    ProjectCollection.upsert_from_catalog!(
      source: 'cellxgene',
      external_key: key,
      title: 'Single cell atlas of the human optic nerve',
      description: 'The optic nerve is essential...'
    )
    pc.reload
    assert_equal 'Single cell atlas of the human optic nerve', pc.title
    assert_equal 'The optic nerve is essential...', pc.description
    assert_not pc.placeholder_title?
  end

  test 'upsert_from_catalog does not overwrite customized title' do
    key = SecureRandom.uuid
    pc = register_for_test_cleanup(
      ProjectCollection.create!(
        source: 'cellxgene',
        external_key: key,
        title: 'My custom collection name',
        description: 'kept'
      )
    )

    ProjectCollection.upsert_from_catalog!(
      source: 'cellxgene',
      external_key: key,
      title: 'Upstream title',
      description: 'Upstream description'
    )
    pc.reload
    assert_equal 'My custom collection name', pc.title
    assert_equal 'kept', pc.description
  end
end
