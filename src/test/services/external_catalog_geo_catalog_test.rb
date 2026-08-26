# frozen_string_literal: true

require 'logger'
require 'test_helper'

class ExternalCatalogGeoCatalogTest < ActiveSupport::TestCase
  setup do
    @catalog = ExternalCatalog::GeoCatalog.new(logger: Logger.new(File::NULL))
  end

  test 'entry_from_summary skips bulk series with only series_matrix' do
    summary = {
      'accession' => 'GSE999001',
      'title' => 'Bulk RNA-seq of liver',
      'ftplink' => 'ftp://ftp.ncbi.nlm.nih.gov/geo/series/GSE999nnn/GSE999001/',
      'gdstype' => 'Expression profiling by high throughput sequencing',
      'n_samples' => 12,
      'taxon' => 'Homo sapiens',
      'taxid' => '9606'
    }
    @catalog.define_singleton_method(:list_geo_files) do |_ftp, _accession|
      [{ name: 'GSE999001_series_matrix.txt.gz', url: 'https://example.com/sm.txt.gz', filesize: 0 }]
    end
    assert_nil @catalog.send(:entry_from_summary, summary, mode: 'bulk')
  end

  test 'entry_from_summary catalogs bulk counts table with n_samples and filesize' do
    summary = {
      'accession' => 'GSE999002',
      'title' => 'Bulk RNA-seq of kidney',
      'ftplink' => 'ftp://ftp.ncbi.nlm.nih.gov/geo/series/GSE999nnn/GSE999002/',
      'gdstype' => 'Expression profiling by high throughput sequencing',
      'n_samples' => 18,
      'taxon' => 'Homo sapiens',
      'taxid' => '9606',
      'pubmedids' => []
    }
    @catalog.define_singleton_method(:list_geo_files) do |_ftp, _accession|
      [
        {
          name: 'GSE999002_series_matrix.txt.gz',
          url: 'https://example.com/sm.txt.gz',
          filesize: 0
        },
        {
          name: 'GSE999002_gene_counts.txt.gz',
          url: 'https://example.com/counts.txt.gz',
          filesize: 0
        }
      ]
    end
    @catalog.define_singleton_method(:remote_filesize) { |_url| 1_234_567 }

    entry = @catalog.send(:entry_from_summary, summary, mode: 'bulk')
    assert entry
    assert_equal 'bulk', entry.project_type_tag
    assert_equal :counts_table, entry.format_kind
    assert_equal 'GSE999002_gene_counts.txt.gz', entry.filename
    assert_equal 18, entry.n_obs
    assert_equal 1_234_567, entry.filesize
  end
end
