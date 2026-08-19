# frozen_string_literal: true

require 'test_helper'

class BasicDeResultIndicesTest < ActiveSupport::TestCase
  PairwiseHeaders = [
    'ensembl_id', 'gene_name', 'log Fold-Change', 'p-value', 'FDR',
    'Avg. Exp. Group 1', 'Avg. Exp. Group 2'
  ].freeze

  AllMarkersHeaders = [
    'Compared group', 'ensembl_id', 'gene_name', 'log Fold-Change', 'p-value', 'FDR',
    'Avg. exp. (tested group)', 'Avg. exp. (other cells)'
  ].freeze

  LegacyMetricHeaders = ['logFC', 'P-value', 'FDR', 'Avg group1', 'Avg group2'].freeze

  StubAnnot = Struct.new(:headers_json_value)

  test 'pairwise v8 headers map metrics after identity columns' do
    annot = StubAnnot.new(PairwiseHeaders.to_json)
    pack = Basic.de_metric_source_indices_for_extract_metadata(annot, 7)
    assert_equal [2, 3, 4, 5, 6], pack[:indices]
    idc = Basic.de_identity_column_indices_for_extract_metadata(annot, 7)
    assert_equal 0, idc[:ensembl]
    assert_equal 1, idc[:gene]
  end

  test 'legacy five metric headers stay at columns 0-4' do
    annot = StubAnnot.new(LegacyMetricHeaders.to_json)
    pack = Basic.de_metric_source_indices_for_extract_metadata(annot, 5)
    assert_equal [0, 1, 2, 3, 4], pack[:indices]
    idc = Basic.de_identity_column_indices_for_extract_metadata(annot, 5)
    assert_nil idc[:ensembl]
    assert_nil idc[:gene]
  end

  test 'stale five metric headers with seven value columns shift by two' do
    annot = StubAnnot.new(LegacyMetricHeaders.to_json)
    pack = Basic.de_metric_source_indices_for_extract_metadata(annot, 7)
    assert_equal [2, 3, 4, 5, 6], pack[:indices]
  end

  test 'FindAllMarkers headers map metrics after group and identity columns' do
    annot = StubAnnot.new(AllMarkersHeaders.to_json)
    pack = Basic.de_metric_source_indices_for_extract_metadata(annot, 8)
    assert_equal [3, 4, 5, 6, 7], pack[:indices]
    idc = Basic.de_identity_column_indices_for_extract_metadata(annot, 8)
    assert_equal 1, idc[:ensembl]
    assert_equal 2, idc[:gene]
  end

  test 'sorted DE matrix row maps gene index from ensembl column not row position' do
    headers = PairwiseHeaders
    annot = StubAnnot.new(headers.to_json)
    identity_idxs = Basic.de_identity_column_indices_for_extract_metadata(annot, 7)
    metric_idxs = Basic.de_metric_source_indices_for_extract_metadata(annot, 7)[:indices]
    # Column-major: identity then metrics. Rows sorted so matrix row 0 is loom gene 2.
    vals = [
      ['ENSG00000000003', 'ENSG00000000005', 'ENSG00000000001'],
      ['TSPAN6', 'CFH', 'A2M'],
      [1.5, -0.2, 0.1],
      [0.001, 0.2, 0.04],
      [0.01, 0.3, 0.05],
      [1.0, 2.0, 3.0],
      [0.5, 0.6, 0.7]
    ]
    ensembl_ids = %w[ENSG00000000001 ENSG00000000003 ENSG00000000005]
    gene_names = %w[A2M TSPAN6 CFH]
    ensembl_to_idx = Basic.de_index_lookup_from_vector(ensembl_ids)
    gene_to_idx = Basic.de_index_lookup_from_vector(gene_names)
    line = Basic.de_output_txt_line_for_matrix_row(
      0, vals, metric_idxs, identity_idxs,
      ensembl_ids, gene_names, {},
      ensembl_to_idx, gene_to_idx, ensembl_ids.size
    )
    cols = line.split("\t")
    assert_equal '1', cols[0]
    assert_equal 'ENSG00000000003', cols[1]
    assert_equal 'TSPAN6', cols[2]
    assert_equal '1.500', cols[5]
  end

  test 'legacy matrix without identity columns keeps loom row index' do
    annot = StubAnnot.new(LegacyMetricHeaders.to_json)
    identity_idxs = Basic.de_identity_column_indices_for_extract_metadata(annot, 5)
    metric_idxs = Basic.de_metric_source_indices_for_extract_metadata(annot, 5)[:indices]
    vals = [
      [0.4, 1.2],
      [0.01, 0.02],
      [0.03, 0.04],
      [1.0, 2.0],
      [3.0, 4.0]
    ]
    ensembl_ids = %w[ENSG1 ENSG2]
    gene_names = %w[G1 G2]
    line = Basic.de_output_txt_line_for_matrix_row(
      1, vals, metric_idxs, identity_idxs,
      ensembl_ids, gene_names, {},
      Basic.de_index_lookup_from_vector(ensembl_ids),
      Basic.de_index_lookup_from_vector(gene_names),
      2
    )
    cols = line.split("\t")
    assert_equal '1', cols[0]
    assert_equal 'ENSG2', cols[1]
    assert_equal 'G2', cols[2]
    assert_equal '1.200', cols[5]
  end
end
