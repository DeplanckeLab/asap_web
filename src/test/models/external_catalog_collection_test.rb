# frozen_string_literal: true

require 'test_helper'

class ExternalCatalogCollectionTest < ActiveSupport::TestCase
  test 'upsert_from_entry creates collection for CELLxGENE and links candidate' do
    external_key = SecureRandom.uuid
    entry = ExternalCatalog::Entry.new(
      source: 'cellxgene',
      external_id: "ds-#{SecureRandom.hex(4)}",
      title: 'Dataset in collection',
      url: 'https://example.com/file.h5ad',
      tax_id: 9606,
      organism_label: 'Homo sapiens',
      filesize: 10,
      project_type_tag: 'sc',
      format_kind: :h5ad,
      filename: 'file.h5ad',
      dois: [],
      pmids: [],
      identifiers: [],
      source_page_url: "https://cellxgene.cziscience.com/collections/#{external_key}",
      collection_id: external_key,
      collection_title: 'My CELLxGENE Collection',
      collection_description: 'Collection description'
    )

    candidate = ExternalCatalogCandidate.upsert_from_entry!(entry)
    register_for_test_cleanup(candidate)
    collection = candidate.external_catalog_collection
    register_for_test_cleanup(collection)

    assert collection.present?
    assert_equal 'cellxgene', collection.source
    assert_equal external_key, collection.external_key
    assert_equal 'My CELLxGENE Collection', collection.title
    assert_equal 'Collection description', collection.description
  end

  test 'upsert_from_entry creates collection for HCA project id' do
    project_id = SecureRandom.uuid
    entry = ExternalCatalog::Entry.new(
      source: 'hca',
      external_id: "#{project_id}::#{SecureRandom.uuid}",
      title: 'HCA file',
      url: 'https://example.com/file.loom',
      tax_id: 9606,
      organism_label: 'Homo sapiens',
      filesize: 10,
      project_type_tag: 'sc',
      format_kind: :loom,
      filename: 'file.loom',
      dois: [],
      pmids: [],
      identifiers: [],
      source_page_url: "https://data.humancellatlas.org/explore/projects/#{project_id}",
      collection_id: project_id,
      collection_title: 'HCA Project Title',
      collection_description: 'HCA project description'
    )

    candidate = ExternalCatalogCandidate.upsert_from_entry!(entry)
    register_for_test_cleanup(candidate)
    collection = candidate.external_catalog_collection
    register_for_test_cleanup(collection)

    assert_equal 'hca', collection.source
    assert_equal project_id, collection.external_key
    assert_equal 'HCA Project Title', collection.title
  end
end
