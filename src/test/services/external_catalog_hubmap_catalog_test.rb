# frozen_string_literal: true

require 'logger'
require 'test_helper'

class ExternalCatalogHubmapCatalogTest < ActiveSupport::TestCase
  setup do
    @catalog = ExternalCatalog::HubmapCatalog.new(logger: Logger.new(File::NULL))
  end

  test 'yields raw out.h5ad entry for public 10x RNAseq dataset' do
    @catalog.define_singleton_method(:search_page) do |from:, size:|
      _ = [from, size]
      {
        'hits' => {
          'total' => { 'value' => 1 },
          'hits' => [
            {
              '_source' => {
                'hubmap_id' => 'HBM243.HRTG.365',
                'uuid' => '81a9fa68b2b4ea3e5f7cb17554149473',
                'title' => 'RNAseq [Salmon] data from the thymus of a 18-year-old male',
                'dataset_type' => 'RNAseq [Salmon]',
                'data_types' => ['salmon_rnaseq_10x'],
                'origin_samples_unique_mapped_organs' => ['Thymus'],
                'files' => [
                  {
                    'rel_path' => 'secondary_analysis.h5ad',
                    'size' => 99,
                    'type' => 'h5ad'
                  },
                  {
                    'rel_path' => 'out.h5ad',
                    'size' => 9_525_744,
                    'type' => 'h5ad',
                    'description' => 'Raw gene expression'
                  }
                ]
              }
            }
          ]
        }
      }
    end

    entries = @catalog.each.to_a
    assert_equal 1, entries.size
    entry = entries.first
    assert_equal 'hubmap', entry.source
    assert_equal 'HBM243.HRTG.365', entry.external_id
    assert_equal 'HUBMAP', entry.provider_tag
    assert_equal 'HuBMAP', entry.provider_name
    assert_equal 'sc', entry.project_type_tag
    assert_equal :h5ad, entry.format_kind
    assert_equal 'out.h5ad', entry.filename
    assert_equal 9_525_744, entry.filesize
    assert_equal 9606, entry.tax_id
    assert_equal 'Homo sapiens', entry.organism_label
    assert_equal(
      'https://assets.hubmapconsortium.org/81a9fa68b2b4ea3e5f7cb17554149473/out.h5ad',
      entry.url
    )
    assert_includes entry.source_page_url, '81a9fa68b2b4ea3e5f7cb17554149473'
    assert_equal 'HBM243.HRTG.365: RNAseq [Salmon] data from the thymus of a 18-year-old male',
                 entry.project_name
  end

  test 'skips datasets without a preferred raw h5ad' do
    @catalog.define_singleton_method(:search_page) do |from:, size:|
      _ = [from, size]
      {
        'hits' => {
          'total' => { 'value' => 1 },
          'hits' => [
            {
              '_source' => {
                'hubmap_id' => 'HBM.SKIP',
                'uuid' => 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
                'title' => 'Markers only',
                'data_types' => ['salmon_rnaseq_10x'],
                'files' => [
                  { 'rel_path' => 'cluster-marker-genes/cluster_marker_genes.h5ad', 'size' => 10 }
                ]
              }
            }
          ]
        }
      }
    end

    assert_empty @catalog.each.to_a
  end

  test 'prefers expr.h5ad when out.h5ad is absent' do
    @catalog.define_singleton_method(:search_page) do |from:, size:|
      _ = [from, size]
      {
        'hits' => {
          'total' => { 'value' => 1 },
          'hits' => [
            {
              '_source' => {
                'hubmap_id' => 'HBM758.GVSL.783',
                'uuid' => 'f6eb890063d13698feb11d39fa61e45a',
                'title' => 'snRNAseq small intestine',
                'data_types' => ['salmon_sn_rnaseq_10x'],
                'files' => [
                  { 'rel_path' => 'secondary_analysis.h5ad', 'size' => 1 },
                  { 'rel_path' => 'expr.h5ad', 'size' => 139_737_320 }
                ]
              }
            }
          ]
        }
      }
    end

    entry = @catalog.each.first
    assert entry
    assert_equal 'expr.h5ad', entry.filename
    assert_equal 139_737_320, entry.filesize
  end

  test 'build_series_key uses hubmap accession' do
    key = ExternalCatalogCandidate.build_series_key(
      source: 'hubmap',
      external_id: 'HBM243.HRTG.365',
      dois: [],
      identifiers: [],
      collection_id: nil
    )
    assert_equal 'hubmap:HBM243.HRTG.365', key
  end
end
