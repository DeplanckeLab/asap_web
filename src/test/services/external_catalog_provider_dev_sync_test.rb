# frozen_string_literal: true

require 'test_helper'

class ExternalCatalogProviderDevSyncTest < ActiveSupport::TestCase
  TAG = 'SYNC_TEST_PROVIDER'

  teardown do
    Provider.where(tag: TAG).delete_all
  end

  test 'apply_row! creates Provider by tag' do
    result = ExternalCatalog::ProviderDevSync.apply_row!(
      name: 'Sync Test Provider',
      description: 'from sync',
      tag: TAG,
      url: 'https://example.com',
      url_mask: 'https://example.com/#{id}',
      attrs_json: '{}'
    )

    record = Provider.find_by(tag: TAG)
    assert_equal :created, result
    assert_equal 'Sync Test Provider', record.name
    assert_equal 'https://example.com/#{id}', record.url_mask
  end

  test 'apply_row! updates Provider fields by tag without changing id' do
    existing = Provider.create!(
      tag: TAG,
      name: 'Old name',
      description: 'old',
      url: nil,
      url_mask: 'https://old.example/#{id}',
      attrs_json: '{}'
    )

    result = ExternalCatalog::ProviderDevSync.apply_row!(
      name: 'New name',
      description: 'new',
      tag: TAG,
      url: 'https://example.com',
      url_mask: 'https://example.com/#{id}',
      attrs_json: '{}'
    )

    record = Provider.find_by(tag: TAG)
    assert_equal :updated, result
    assert_equal existing.id, record.id
    assert_equal 'New name', record.name
    assert_equal 'https://example.com/#{id}', record.url_mask
  end

  test 'apply_row! returns unchanged when attributes match' do
    Provider.create!(
      tag: TAG,
      name: 'Same',
      description: nil,
      url: nil,
      url_mask: 'https://example.com/#{id}',
      attrs_json: '{}'
    )

    result = ExternalCatalog::ProviderDevSync.apply_row!(
      name: 'Same',
      description: nil,
      tag: TAG,
      url: nil,
      url_mask: 'https://example.com/#{id}',
      attrs_json: '{}'
    )

    assert_equal :unchanged, result
  end

  test 'prepare_row maps source attributes' do
    prepared = ExternalCatalog::ProviderDevSync.prepare_row(
      'id' => 99,
      'name' => 'EBI SC',
      'description' => 'desc',
      'tag' => 'EBI_SC',
      'url' => nil,
      'url_mask' => 'https://www.ebi.ac.uk/gxa/sc/experiments/#{id}',
      'attrs_json' => '{}'
    )

    assert_equal 'EBI_SC', prepared[:tag]
    assert_equal 'EBI SC', prepared[:name]
    assert_nil prepared[:url]
    refute prepared.key?(:id)
  end
end
