# frozen_string_literal: true

require 'test_helper'

class ProjectCollectionPermissionsTest < ActiveSupport::TestCase
  test 'owner can only claim ownership of manual collections they create' do
    owner = register_for_test_cleanup(
      User.create!(email: "owner_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )
    other = register_for_test_cleanup(
      User.create!(email: "other_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )

    own = register_for_test_cleanup(
      ProjectCollection.create_manual!(title: "Own #{SecureRandom.hex(3)}", created_by_user: owner)
    )
    foreign = register_for_test_cleanup(
      ProjectCollection.create_manual!(title: "Foreign #{SecureRandom.hex(3)}", created_by_user: other)
    )
    catalog = register_for_test_cleanup(
      ProjectCollection.upsert_from_catalog!(
        source: 'cellxgene',
        external_key: SecureRandom.uuid,
        title: 'Catalog backed'
      )
    )

    assert own.owned_by?(owner)
    assert_not own.owned_by?(other)
    assert_not foreign.owned_by?(owner)
    assert catalog.catalog_backed?
    assert_not catalog.owned_by?(owner)
  end
end
