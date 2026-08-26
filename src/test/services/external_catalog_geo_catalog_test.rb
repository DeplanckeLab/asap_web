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

  test 'entry_from_summary skips bulk series with fewer than 2 samples' do
    summary = {
      'accession' => 'GSE999003',
      'title' => 'Bulk RNA-seq single sample',
      'ftplink' => 'ftp://ftp.ncbi.nlm.nih.gov/geo/series/GSE999nnn/GSE999003/',
      'gdstype' => 'Expression profiling by high throughput sequencing',
      'n_samples' => 1,
      'taxon' => 'Homo sapiens',
      'taxid' => '9606'
    }
    listed = false
    @catalog.define_singleton_method(:list_geo_files) do |_ftp, _accession|
      listed = true
      [{ name: 'GSE999003_counts.txt.gz', url: 'https://example.com/c.txt.gz', filesize: 1_000_000 }]
    end
    assert_nil @catalog.send(:entry_from_summary, summary, mode: 'bulk')
    assert_equal false, listed
  end

  test 'entry_from_summary keeps bulk series with 2 samples' do
    summary = {
      'accession' => 'GSE999005',
      'title' => 'Bulk RNA-seq two samples',
      'ftplink' => 'ftp://ftp.ncbi.nlm.nih.gov/geo/series/GSE999nnn/GSE999005/',
      'gdstype' => 'Expression profiling by high throughput sequencing',
      'n_samples' => 2,
      'taxon' => 'Homo sapiens',
      'taxid' => '9606',
      'pubmedids' => []
    }
    @catalog.define_singleton_method(:list_geo_files) do |_ftp, _accession|
      [{ name: 'GSE999005_counts.txt.gz', url: 'https://example.com/c.txt.gz', filesize: 500_000 }]
    end
    entry = @catalog.send(:entry_from_summary, summary, mode: 'bulk')
    assert entry
    assert_equal 2, entry.n_obs
  end

  test 'entry_from_summary only_bulk_samples skips other sample counts before FTP' do
    summary = {
      'accession' => 'GSE999006',
      'title' => 'Bulk RNA-seq four samples',
      'ftplink' => 'ftp://ftp.ncbi.nlm.nih.gov/geo/series/GSE999nnn/GSE999006/',
      'gdstype' => 'Expression profiling by high throughput sequencing',
      'n_samples' => 4,
      'taxon' => 'Homo sapiens',
      'taxid' => '9606'
    }
    listed = false
    @catalog.define_singleton_method(:list_geo_files) do |_ftp, _accession|
      listed = true
      [{ name: 'GSE999006_counts.txt.gz', url: 'https://example.com/c.txt.gz', filesize: 500_000 }]
    end
    assert_nil @catalog.send(:entry_from_summary, summary, mode: 'bulk', only_bulk_samples: 2)
    assert_equal false, listed
  end

  test 'entry_from_summary skips tiny bulk archive_table files' do
    summary = {
      'accession' => 'GSE999004',
      'title' => 'Bulk RNA-seq with empty RAW.tar',
      'ftplink' => 'ftp://ftp.ncbi.nlm.nih.gov/geo/series/GSE999nnn/GSE999004/',
      'gdstype' => 'Expression profiling by high throughput sequencing',
      'n_samples' => 4,
      'taxon' => 'Homo sapiens',
      'taxid' => '9606',
      'pubmedids' => []
    }
    @catalog.define_singleton_method(:list_geo_files) do |_ftp, _accession|
      [{ name: 'GSE999004_RAW.tar', url: 'https://example.com/RAW.tar', filesize: 10_240 }]
    end
    assert_nil @catalog.send(:entry_from_summary, summary, mode: 'bulk')
  end

  test 'each skips accessions in skip_accessions before FTP listing' do
    listed = []
    @catalog.define_singleton_method(:esearch_ids) { |**_| %w[1] }
    @catalog.define_singleton_method(:esummary) do |_ids|
      [{
        'accession' => 'GSE888001',
        'title' => 'Bulk RNA-seq',
        'ftplink' => 'ftp://ftp.ncbi.nlm.nih.gov/geo/series/GSE888nnn/GSE888001/',
        'gdstype' => 'Expression profiling by high throughput sequencing',
        'n_samples' => 4,
        'taxon' => 'Homo sapiens',
        'taxid' => '9606'
      }]
    end
    @catalog.define_singleton_method(:list_geo_files) do |_ftp, accession|
      listed << accession
      [{ name: 'GSE888001_counts.txt.gz', url: 'https://example.com/c.txt.gz', filesize: 10 }]
    end

    yielded = []
    @catalog.each(mode: 'bulk', skip_accessions: ['GSE888001']) { |e| yielded << e }
    assert_empty yielded
    assert_empty listed

    @catalog.each(mode: 'bulk', skip_accessions: []) { |e| yielded << e }
    assert_equal 1, yielded.size
    assert_equal ['GSE888001'], listed
  end

  test 'eutils_get_json retries on HTTP 429 then succeeds' do
    calls = 0
    @catalog.define_singleton_method(:sleep) { |_s| }
    @catalog.define_singleton_method(:throttle_eutils!) { }
    @catalog.define_singleton_method(:perform_eutils_get) do |_url, query:|
      calls += 1
      if calls == 1
        Struct.new(:code, :body).new(429, 'slow down').tap do |r|
          r.define_singleton_method(:success?) { false }
        end
      else
        Struct.new(:code, :body).new(200, '{"ok":true}').tap do |r|
          r.define_singleton_method(:success?) { true }
        end
      end
    end

    body = @catalog.send(:eutils_get_json, 'esearch.fcgi', { db: 'gds' }, label: 'test')
    assert_equal({ 'ok' => true }, body)
    assert_equal 2, calls
  end
end
