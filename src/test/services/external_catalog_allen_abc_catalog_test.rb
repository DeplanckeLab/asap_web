# frozen_string_literal: true

require 'logger'
require 'test_helper'

class ExternalCatalogAllenAbcCatalogTest < ActiveSupport::TestCase
  setup do
    @catalog = ExternalCatalog::AllenAbcCatalog.new(logger: Logger.new(File::NULL))
  end

  test 'yields raw h5ad entries for included 10x directories' do
    @catalog.define_singleton_method(:fetch_manifest) do
      {
        'version' => '20260711',
        'file_listing' => {
          'WMB-10Xv3' => {
            'expression_matrices' => {
              'WMB-10Xv3-TH' => {
                'raw' => {
                  'files' => {
                    'h5ad' => {
                      'url' => 'https://allen-brain-cell-atlas.s3.us-west-2.amazonaws.com/expression_matrices/WMB-10Xv3/20230630/WMB-10Xv3-TH-raw.h5ad',
                      'size' => 5_811_140_682,
                      'relative_path' => 'expression_matrices/WMB-10Xv3/20230630/WMB-10Xv3-TH-raw.h5ad'
                    }
                  }
                },
                'log2' => {
                  'files' => {
                    'h5ad' => {
                      'url' => 'https://example.com/log2.h5ad',
                      'size' => 1,
                      'relative_path' => 'log2.h5ad'
                    }
                  }
                }
              }
            }
          },
          'MERFISH-C57BL6J-638850' => {
            'expression_matrices' => {
              'C57BL6J-638850' => {
                'raw' => {
                  'files' => {
                    'h5ad' => {
                      'url' => 'https://example.com/merfish-raw.h5ad',
                      'size' => 100,
                      'relative_path' => 'merfish-raw.h5ad'
                    }
                  }
                }
              }
            }
          }
        }
      }
    end

    entries = @catalog.each.to_a
    assert_equal 1, entries.size
    entry = entries.first
    assert_equal 'allen_abc', entry.source
    assert_equal 'WMB-10Xv3-TH', entry.external_id
    assert_equal 'ALLEN_ABC', entry.provider_tag
    assert_equal 'Allen Brain Cell Atlas', entry.provider_name
    assert_equal 'sc', entry.project_type_tag
    assert_equal :h5ad, entry.format_kind
    assert_equal 'WMB-10Xv3-TH-raw.h5ad', entry.filename
    assert_equal 5_811_140_682, entry.filesize
    assert_equal 10090, entry.tax_id
    assert_equal 'Mus musculus', entry.organism_label
    assert_equal 'WMB-10Xv3', entry.collection_id
    assert_includes entry.url, 'WMB-10Xv3-TH-raw.h5ad'
    assert_equal 'WMB-10Xv3 / WMB-10Xv3-TH (Allen Brain Cell Atlas 20260711)',
                 entry.project_name
  end

  test 'skips packages that only have log2 matrices' do
    @catalog.define_singleton_method(:fetch_manifest) do
      {
        'version' => '20260711',
        'file_listing' => {
          'WMB-10Xv3' => {
            'expression_matrices' => {
              'WMB-10Xv3-TH' => {
                'log2' => {
                  'files' => {
                    'h5ad' => {
                      'url' => 'https://example.com/log2.h5ad',
                      'size' => 1,
                      'relative_path' => 'log2.h5ad'
                    }
                  }
                }
              }
            }
          }
        }
      }
    end

    assert_empty @catalog.each.to_a
  end

  test 'build_series_key uses allen_abc accession' do
    key = ExternalCatalogCandidate.build_series_key(
      source: 'allen_abc',
      external_id: 'WMB-10Xv3-TH',
      dois: [],
      identifiers: [],
      collection_id: 'WMB-10Xv3'
    )
    assert_equal 'allen_abc:WMB-10Xv3-TH', key
  end
end
