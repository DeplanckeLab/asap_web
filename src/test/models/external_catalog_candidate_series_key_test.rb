# frozen_string_literal: true

require 'test_helper'

class ExternalCatalogCandidateSeriesKeyTest < ActiveSupport::TestCase
  test 'build_series_key prefers DOI over GEO and collection' do
    key = ExternalCatalogCandidate.build_series_key(
      source: 'cellxgene',
      external_id: 'dataset-1',
      dois: ['https://doi.org/10.1016/j.isci.2022.104097'],
      identifiers: [{ kind: 'geo_series', value: 'GSE190094' }],
      collection_id: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
    )

    assert_equal 'doi:10.1016/j.isci.2022.104097', key
  end

  test 'build_series_key uses geo_series when DOI missing' do
    key = ExternalCatalogCandidate.build_series_key(
      source: 'cellxgene',
      external_id: 'dataset-1',
      dois: [],
      identifiers: [{ kind: 'geo_series', value: 'GSE190094' }],
      collection_id: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
    )

    assert_equal 'geo_series:GSE190094', key
  end

  test 'build_series_key uses collection when DOI and GEO missing' do
    key = ExternalCatalogCandidate.build_series_key(
      source: 'cellxgene',
      external_id: 'dataset-1',
      dois: [],
      identifiers: [],
      collection_id: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
    )

    assert_equal 'collection:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee', key
  end

  test 'build_series_key for GEO source uses external_id' do
    key = ExternalCatalogCandidate.build_series_key(
      source: 'geo',
      external_id: 'gse12345',
      dois: [],
      identifiers: [],
      collection_id: nil
    )

    assert_equal 'geo_series:GSE12345', key
  end

  test 'collection_id_from_source_page_url parses CELLxGENE collection URL' do
    url = 'https://cellxgene.cziscience.com/collections/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
    assert_equal 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
                 ExternalCatalogCandidate.collection_id_from_source_page_url(url)
  end

  test 'upsert_from_entry assigns series_key and collection_id' do
    entry = ExternalCatalog::Entry.new(
      source: 'cellxgene',
      external_id: "ds-#{SecureRandom.hex(4)}",
      title: 'Spatial transcriptomics in mouse: Puck_1',
      url: 'https://example.com/file.h5ad',
      tax_id: 10090,
      organism_label: 'Mus musculus',
      filesize: 100,
      project_type_tag: 'sc',
      format_kind: :h5ad,
      filename: 'file.h5ad',
      dois: ['10.1016/j.isci.2022.104097'],
      pmids: [],
      identifiers: [{ kind: 'geo_series', value: 'GSE190094' }],
      source_page_url: 'https://cellxgene.cziscience.com/collections/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
      collection_id: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
    )

    record = ExternalCatalogCandidate.upsert_from_entry!(entry)

    assert_equal 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee', record.collection_id
    assert_equal 'doi:10.1016/j.isci.2022.104097', record.series_key
  ensure
    record&.destroy
  end

  test 'ordered_for_catalog groups by series_key then title' do
    suffix = SecureRandom.hex(3)
    a = ExternalCatalogCandidate.create!(
      source: 'cellxgene',
      external_id: "a-#{suffix}",
      provider_tag: 'CELLxGENE',
      title: 'B title',
      dois_json: ['10.1/aaa'].to_json,
      import_status: 'idle',
      tax_id: 9606
    )
    b = ExternalCatalogCandidate.create!(
      source: 'cellxgene',
      external_id: "b-#{suffix}",
      provider_tag: 'CELLxGENE',
      title: 'A title',
      dois_json: ['10.1/aaa'].to_json,
      import_status: 'idle',
      tax_id: 9606
    )
    c = ExternalCatalogCandidate.create!(
      source: 'cellxgene',
      external_id: "c-#{suffix}",
      provider_tag: 'CELLxGENE',
      title: 'C title',
      dois_json: ['10.1/bbb'].to_json,
      import_status: 'idle',
      tax_id: 9606
    )

    ordered = ExternalCatalogCandidate.where(id: [a.id, b.id, c.id]).ordered_for_catalog.to_a
    assert_equal [b.id, a.id, c.id], ordered.map(&:id)
  ensure
    ExternalCatalogCandidate.where(id: [a&.id, b&.id, c&.id].compact).delete_all
  end
end
