# frozen_string_literal: true

require 'logger'
require 'test_helper'

class ExternalCatalogBroadScpCatalogTest < ActiveSupport::TestCase
  setup do
    @logger = Logger.new(File::NULL)
    @previous_token = ENV['SCP_ACCESS_TOKEN']
  end

  teardown do
    if @previous_token.nil?
      ENV.delete('SCP_ACCESS_TOKEN')
    else
      ENV['SCP_ACCESS_TOKEN'] = @previous_token
    end
  end

  test 'yields AnnData entry with collection and publication DOI' do
    catalog = ExternalCatalog::BroadScpCatalog.new(logger: @logger)
    catalog.define_singleton_method(:fetch_collection_memberships) do
      {
        'SCP3828' => {
          id: 'human-cell-atlas-main-collection',
          title: 'Human Cell Atlas - Main Collection',
          url: 'https://singlecell.broadinstitute.org/single_cell?scpbr=human-cell-atlas-main-collection'
        }
      }
    end
    catalog.define_singleton_method(:each_search_study) do |&block|
      block.call(
        'SCP3828',
        {
          'accession' => 'SCP3828',
          'name' => 'Prox1 program',
          'cell_count' => 384_575,
          'gene_count' => 12_000,
          'study_url' => '/single_cell/study/SCP3828/prox1',
          'metadata' => { 'species' => ['Mus musculus'] }
        }
      )
      block.call(
        'SCP-SKIP',
        {
          'accession' => 'SCP-SKIP',
          'name' => 'MTX only',
          'metadata' => { 'species' => ['Homo sapiens'] }
        }
      )
    end
    catalog.define_singleton_method(:fetch_json) do |url, query: nil|
      _ = query
      case url
      when %r{/site/studies/SCP3828\z}
        {
          'accession' => 'SCP3828',
          'name' => 'Prox1 program',
          'cell_count' => 384_575,
          'gene_count' => 12_000,
          'publications' => [
            { 'url' => 'https://www.science.org/doi/10.1126/science.aad7038', 'pmcid' => 'PMC5480621' }
          ],
          'external_resources' => [
            { 'url' => 'https://www.ncbi.nlm.nih.gov/geo/query/acc.cgi?acc=GSE12345' }
          ],
          'study_files' => [
            {
              'file_type' => 'AnnData',
              'name' => 'merfish_E13_processed_SCP.h5ad',
              'bucket_location' => 'merfish_E13_processed_SCP.h5ad',
              'upload_file_size' => 261_228_513,
              'download_url' =>
                'https://singlecell.broadinstitute.org/single_cell/api/v1/site/studies/SCP3828/download?filename=merfish_E13_processed_SCP.h5ad'
            }
          ]
        }
      when %r{/site/studies/SCP-SKIP\z}
        {
          'accession' => 'SCP-SKIP',
          'name' => 'MTX only',
          'study_files' => [
            {
              'file_type' => 'MM Coordinate Matrix',
              'name' => 'matrix.mtx',
              'bucket_location' => 'matrix.mtx',
              'upload_file_size' => 100,
              'download_url' =>
                'https://singlecell.broadinstitute.org/single_cell/api/v1/site/studies/SCP-SKIP/download?filename=matrix.mtx'
            },
            {
              'file_type' => '10X Genes File',
              'name' => 'features.tsv',
              'bucket_location' => 'features.tsv',
              'upload_file_size' => 10,
              'download_url' =>
                'https://singlecell.broadinstitute.org/single_cell/api/v1/site/studies/SCP-SKIP/download?filename=features.tsv'
            },
            {
              'file_type' => '10X Barcodes File',
              'name' => 'barcodes.tsv',
              'bucket_location' => 'barcodes.tsv',
              'upload_file_size' => 10,
              'download_url' =>
                'https://singlecell.broadinstitute.org/single_cell/api/v1/site/studies/SCP-SKIP/download?filename=barcodes.tsv'
            }
          ]
        }
      else
        raise "unexpected url #{url}"
      end
    end

    entries = catalog.each.to_a
    assert_equal 1, entries.size
    entry = entries.first
    assert_equal 'broad_scp', entry.source
    assert_equal 'SCP3828', entry.external_id
    assert_equal 'BROAD_SCP', entry.provider_tag
    assert_equal 'Broad Single Cell Portal', entry.provider_name
    assert_equal 'SCP3828: Prox1 program', entry.project_name
    assert_equal 10090, entry.tax_id
    assert_equal 'Mus musculus', entry.organism_label
    assert_equal 384_575, entry.n_obs
    assert_equal 12_000, entry.n_vars
    assert_equal :h5ad, entry.format_kind
    assert_equal 'merfish_E13_processed_SCP.h5ad', entry.filename
    assert_includes entry.url, 'SCP3828/download'
    assert_equal 'human-cell-atlas-main-collection', entry.collection_id
    assert_equal 'Human Cell Atlas - Main Collection', entry.collection_title
    assert_equal ['10.1126/science.aad7038'], entry.normalized_dois
    assert_equal 'geo_series', entry.normalized_identifiers.first[:kind]
    assert_equal 'GSE12345', entry.normalized_identifiers.first[:value]
  end

  test 'prefer_raw_or_smallest picks raw AnnData when several exist' do
    catalog = ExternalCatalog::BroadScpCatalog.new(logger: @logger)
    files = [
      { 'name' => 'study.h5ad', 'upload_file_size' => 100 },
      { 'name' => 'study_raw_counts.h5ad', 'upload_file_size' => 200 },
      { 'name' => 'study_processed.h5ad', 'upload_file_size' => 50 }
    ]
    picked = catalog.send(:prefer_raw_or_smallest, files)
    assert_equal 'study_raw_counts.h5ad', picked['name']
  end

  test 'authorization_header_for! requires SCP_ACCESS_TOKEN for portal download URLs' do
    ENV.delete('SCP_ACCESS_TOKEN')
    url = 'https://singlecell.broadinstitute.org/single_cell/api/v1/site/studies/SCP1/download?filename=x.h5ad'
    assert_raises(ExternalCatalog::BroadScpCatalog::MissingAccessToken) do
      ExternalCatalog::BroadScpCatalog.authorization_header_for!(url)
    end

    ENV['SCP_ACCESS_TOKEN'] = 'token-abc'
    assert_equal 'Bearer token-abc', ExternalCatalog::BroadScpCatalog.authorization_header_for!(url)
    assert_nil ExternalCatalog::BroadScpCatalog.authorization_header_for!('https://example.com/file.h5ad')
  end

  test 'upsert_from_entry! creates broad_scp catalog collection' do
    entry = ExternalCatalog::Entry.new(
      source: 'broad_scp',
      external_id: 'SCP9999',
      title: 'Test study',
      url: 'https://singlecell.broadinstitute.org/single_cell/api/v1/site/studies/SCP9999/download?filename=a.h5ad',
      tax_id: 9606,
      organism_label: 'Homo sapiens',
      filesize: 10,
      project_type_tag: 'sc',
      format_kind: :h5ad,
      filename: 'a.h5ad',
      dois: [],
      pmids: [],
      identifiers: [],
      source_page_url: 'https://singlecell.broadinstitute.org/single_cell/study/SCP9999',
      collection_id: 'immune-cell-atlas',
      collection_title: 'Immune Cell Atlas'
    )
    candidate = ExternalCatalogCandidate.upsert_from_entry!(entry)
    assert_equal 'broad_scp', candidate.source
    assert_equal 'immune-cell-atlas', candidate.collection_id
    assert candidate.external_catalog_collection
    assert_equal 'Immune Cell Atlas', candidate.external_catalog_collection.title
    assert_includes candidate.external_catalog_collection.source_page_url, 'scpbr=immune-cell-atlas'
    assert_equal 'scp:SCP9999', candidate.series_key
  ensure
    candidate&.destroy!
    ExternalCatalogCollection.where(source: 'broad_scp', external_key: 'immune-cell-atlas').delete_all
  end
end
