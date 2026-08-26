# frozen_string_literal: true

require 'test_helper'

class ExternalCatalogFormatPriorityTest < ActiveSupport::TestCase
  test 'pick_geo_bulk_file prefers counts table over archive and ignores series_matrix' do
    names = [
      'GSE1_series_matrix.txt.gz',
      'GSE1_raw_counts.txt.gz',
      'GSE1_suppl.tar.gz'
    ]
    picked = ExternalCatalog::FormatPriority.pick_geo_bulk_file(names)
    assert_equal ['GSE1_raw_counts.txt.gz', :counts_table], picked
  end

  test 'pick_geo_bulk_file does not catalog series_matrix alone' do
    names = ['GSE1_series_matrix.txt.gz', 'GSE1-GPL123_series_matrix.txt.gz']
    assert_nil ExternalCatalog::FormatPriority.pick_geo_bulk_file(names)
  end

  test 'pick_geo_bulk_file falls back to archive when no counts table' do
    names = ['GSE1_series_matrix.txt.gz', 'GSE1_RAW.tar']
    picked = ExternalCatalog::FormatPriority.pick_geo_bulk_file(names)
    assert_equal ['GSE1_RAW.tar', :archive_table], picked
  end

  test 'pick_geo_sc_file prefers loom over h5ad' do
    names = ['a.h5ad', 'b.loom', 'c.mtx.gz']
    picked = ExternalCatalog::FormatPriority.pick_geo_sc_file(names)
    assert_equal ['b.loom', :loom], picked
  end
end
