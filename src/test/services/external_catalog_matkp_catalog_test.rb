# frozen_string_literal: true

require 'logger'
require 'test_helper'

class ExternalCatalogMatkpCatalogTest < ActiveSupport::TestCase
  setup do
    @catalog = ExternalCatalog::MatkpCatalog.new(logger: Logger.new(File::NULL))
  end

  test 'yields single_cell rows with download_public zip urls' do
    @catalog.define_singleton_method(:fetch_rows) do
      [
        {
          'data_type' => 'single_cell',
          'datasetId' => 'SingleCell_Li2022_Mouse_SCP708_WC_ING',
          'datasetName' => 'Single cell RNA-seq of mouse white adipose tissue',
          'species' => 'Mus musculus',
          'depot' => 'subcutaneous adipose tissue',
          'depot2' => 'inguinal fat pad',
          'download_public' => 'https://api.kpndataregistry.org/api/d/8VUw3t',
          'doi' => 'https://doi.org/10.1038/s41586-021-03514-2',
          'pmid' => '33972757',
          'sourceDataset' => 'GSE176171',
          'totalSamples' => 7608
        },
        {
          'data_type' => 'bulk_rna',
          'datasetId' => 'bulkRNA_Emont2022_Humans_SAT',
          'datasetName' => 'Bulk',
          'species' => 'Homo sapiens',
          'download_public' => 'https://api.kpndataregistry.org/api/d/xxxx'
        },
        {
          'data_type' => 'single_cell',
          'datasetId' => 'snRNA_no_download',
          'datasetName' => 'No public matrix',
          'species' => 'Homo sapiens',
          'download_public' => nil
        }
      ]
    end
    @catalog.define_singleton_method(:probe_filesize) { |_url| 23_345_732 }

    entries = @catalog.each.to_a
    assert_equal 1, entries.size
    entry = entries.first
    assert_equal 'matkp', entry.source
    assert_equal 'SingleCell_Li2022_Mouse_SCP708_WC_ING', entry.external_id
    assert_equal 'MATKP', entry.provider_tag
    assert_equal 'MATKP', entry.provider_name
    assert_equal 'sc', entry.project_type_tag
    assert_equal :zip, entry.format_kind
    assert_equal 'SingleCell_Li2022_Mouse_SCP708_WC_ING.zip', entry.filename
    assert_equal 23_345_732, entry.filesize
    assert_equal 7608, entry.n_obs
    assert_equal 10090, entry.tax_id
    assert_equal 'Mus musculus', entry.organism_label
    assert_equal 'https://api.kpndataregistry.org/api/d/8VUw3t', entry.url
    assert_equal ['10.1038/s41586-021-03514-2'], entry.normalized_dois
    assert_equal ['33972757'], entry.normalized_pmids
    assert_equal 'geo_series', entry.normalized_identifiers.first[:kind]
    assert_equal 'GSE176171', entry.normalized_identifiers.first[:value]
    assert_includes entry.title, 'inguinal fat pad'
    assert_equal(
      'SingleCell_Li2022_Mouse_SCP708_WC_ING: Single cell RNA-seq of mouse white adipose tissue ' \
      '(subcutaneous adipose tissue, inguinal fat pad)',
      entry.project_name
    )
  end

  test 'build_series_key uses matkp accession' do
    key = ExternalCatalogCandidate.build_series_key(
      source: 'matkp',
      external_id: 'SingleCell_Li2022_Mouse_SCP708_WC_ING',
      dois: [],
      identifiers: [],
      collection_id: nil
    )
    assert_equal 'matkp:SingleCell_Li2022_Mouse_SCP708_WC_ING', key
  end
end
