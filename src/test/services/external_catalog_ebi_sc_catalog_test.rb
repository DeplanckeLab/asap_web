# frozen_string_literal: true

require 'logger'
require 'test_helper'

class ExternalCatalogEbiScCatalogTest < ActiveSupport::TestCase
  setup do
    @logger = Logger.new(File::NULL)
  end

  test 'yields project.h5ad entries with metadata from experiments JSON and IDF' do
    catalog = ExternalCatalog::EbiScCatalog.new(logger: @logger)
    catalog.define_singleton_method(:list_experiment_accessions) do
      ['E-CURD-118', 'E-SKIP-1']
    end
    catalog.define_singleton_method(:fetch_experiment_metadata) do
      {
        'E-CURD-118' => {
          'experimentAccession' => 'E-CURD-118',
          'experimentDescription' => 'Plasma cells after infection',
          'species' => 'Homo sapiens',
          'numberOfAssays' => 1234
        }
      }
    end
    catalog.define_singleton_method(:list_directory_files) do |url|
      if url.include?('E-CURD-118')
        [{
          name: 'E-CURD-118.project.h5ad',
          url: "#{ExternalCatalog::EbiScCatalog::FTP_BASE}/E-CURD-118/E-CURD-118.project.h5ad",
          filesize: 438 * 1024 * 1024
        }]
      else
        []
      end
    end
    catalog.define_singleton_method(:fetch_publication_ids) do |_accession|
      [['10.1002/eji.202149331'], ['34727578']]
    end

    entries = catalog.each.to_a
    assert_equal 1, entries.size
    entry = entries.first
    assert_equal 'ebi_sc', entry.source
    assert_equal 'E-CURD-118', entry.external_id
    assert_equal 'EBI_SC', entry.provider_tag
    assert_equal 'EBI single cell expression atlas', entry.provider_name
    assert_equal 'Plasma cells after infection', entry.title
    assert_equal 'E-CURD-118: Plasma cells after infection', entry.project_name
    assert_equal 9606, entry.tax_id
    assert_equal 'Homo sapiens', entry.organism_label
    assert_equal 1234, entry.n_obs
    assert_equal :h5ad, entry.format_kind
    assert_equal 'E-CURD-118.project.h5ad', entry.filename
    assert_includes entry.url, 'E-CURD-118.project.h5ad'
    assert_equal ['10.1002/eji.202149331'], entry.normalized_dois
    assert_equal ['34727578'], entry.normalized_pmids
    assert_equal 'array_express', entry.normalized_identifiers.first[:kind]
  end

  test 'parse_apache_size handles K/M/G labels' do
    catalog = ExternalCatalog::EbiScCatalog.new(logger: @logger)
    assert_equal 1024, catalog.send(:parse_apache_size, '1K')
    assert_equal (6.6 * 1024**2).round, catalog.send(:parse_apache_size, '6.6M')
    assert_equal (13 * 1024**3), catalog.send(:parse_apache_size, '13G')
    assert_equal 0, catalog.send(:parse_apache_size, '-')
  end

  test 'adds GEO series identifier for E-GEOD accessions' do
    catalog = ExternalCatalog::EbiScCatalog.new(logger: @logger)
    catalog.define_singleton_method(:list_experiment_accessions) { ['E-GEOD-36552'] }
    catalog.define_singleton_method(:fetch_experiment_metadata) do
      {
        'E-GEOD-36552' => {
          'experimentAccession' => 'E-GEOD-36552',
          'experimentDescription' => 'Human ESC',
          'species' => 'Homo sapiens',
          'numberOfAssays' => 10
        }
      }
    end
    catalog.define_singleton_method(:pick_h5ad_file) do |_acc|
      {
        name: 'E-GEOD-36552.project.h5ad',
        url: "#{ExternalCatalog::EbiScCatalog::FTP_BASE}/E-GEOD-36552/E-GEOD-36552.project.h5ad",
        filesize: 42
      }
    end
    catalog.define_singleton_method(:fetch_publication_ids) { |_acc| [[], []] }

    entry = catalog.each.first
    kinds = entry.normalized_identifiers.map { |h| h[:kind] }
    assert_includes kinds, 'array_express'
    assert_includes kinds, 'geo_series'
    assert_equal 'GSE36552', entry.normalized_identifiers.find { |h| h[:kind] == 'geo_series' }[:value]
  end
end
