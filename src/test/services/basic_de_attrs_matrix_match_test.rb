# frozen_string_literal: true

require 'test_helper'

class BasicDeAttrsMatrixMatchTest < ActiveSupport::TestCase
  test 'matches classic combinatorial path de_<run_id>_<k>' do
    assert_equal [835550, 2], Basic.de_attrs_de_output_matrix_match('/attrs/de_835550_2')
    assert_equal [10, 0], Basic.de_attrs_de_output_matrix_match('attrs/de_10_0')
  end

  test 'matches v8 tool write-metadata path _de_<run_num>_<method>' do
    assert_equal [nil, 0], Basic.de_attrs_de_output_matrix_match('/attrs/_de_3_wilcoxon')
    assert_equal [nil, 0], Basic.de_attrs_de_output_matrix_match('/attrs/_de_11_t_test')
  end

  test 'rejects non-DE attrs paths' do
    assert_nil Basic.de_attrs_de_output_matrix_match('/attrs/LOOM_SPEC_VERSION')
    assert_nil Basic.de_attrs_de_output_matrix_match('/attrs/_de_test')
    assert_nil Basic.de_attrs_de_output_matrix_match('/col_attrs/cell_type')
  end

  test 'de_attrs_de_output_match_for_run_id? uses Annot.run_id for v8 paths' do
    annot = Struct.new(:run_id).new(835550)
    m = Basic.de_attrs_de_output_matrix_match('/attrs/_de_3_wilcoxon')
    assert Basic.de_attrs_de_output_match_for_run_id?(m, 835550, annot: annot)
    refute Basic.de_attrs_de_output_match_for_run_id?(m, 1, annot: annot)
  end

  test 'de_attrs_de_output_match_for_run_id? uses encoded run id for classic paths' do
    m = Basic.de_attrs_de_output_matrix_match('/attrs/de_835550_1')
    assert Basic.de_attrs_de_output_match_for_run_id?(m, 835550, annot: nil)
    refute Basic.de_attrs_de_output_match_for_run_id?(m, 1, annot: nil)
  end

  test 'de_annot_output_txt_path uses Annot.run_id for v8 _de_ paths' do
    annot = Struct.new(:id, :name, :run_id).new(6069211, '/attrs/_de_3_wilcoxon', 835550)
    path = Basic.de_annot_output_txt_path('/tmp/proj', annot)
    assert_equal '/tmp/proj/de/835550/annot_6069211/output.txt', path.to_s
  end

  test 'de_de_filter_stats_key uses run.id for v8 _de_ paths' do
    run = Struct.new(:id).new(835550)
    annot = Struct.new(:name, :run_id).new('/attrs/_de_3_wilcoxon', 835550)
    key = Basic.de_de_filter_stats_key(run, annot: annot, reference_group: '0', contrast_index: 0)
    assert_equal '835550__0_0', key
  end

  test 'de_output_txt_needs_rebuild? accepts identity layout when headers_json missing' do
    Dir.mktmpdir('de_rebuild') do |dir|
      path = File.join(dir, 'output.txt')
      layout = File.join(dir, 'output.layout')
      File.write(path, ([0, 'ENSG1', 'G', nil, nil, 1.0, 0.1, 0.01, 1.0, 2.0, 0.5, 0.5].join("\t") + "\n"))
      File.write(layout, "#{Basic::DE_OUTPUT_TXT_LAYOUT_IDENTITY}\n")
      annot = Struct.new(:headers_json_value).new(nil)
      refute Basic.de_output_txt_needs_rebuild?(path, annot)
    end
  end

  test 'de_output_txt_needs_rebuild? still requires expected ncols when headers present' do
    Dir.mktmpdir('de_rebuild') do |dir|
      path = File.join(dir, 'output.txt')
      layout = File.join(dir, 'output.layout')
      # 10 cols but headers imply 12
      File.write(path, ([0, 'ENSG1', 'G', nil, nil, 1.0, 0.1, 0.01, 1.0, 2.0].join("\t") + "\n"))
      File.write(layout, "#{Basic::DE_OUTPUT_TXT_LAYOUT_IDENTITY}\n")
      headers = [
        'ensembl_id', 'gene_name', 'log Fold-Change', 'p-value', 'FDR',
        'Avg. Exp. Group 1', 'Avg. Exp. Group 2', 'Tau', 'Specificity'
      ]
      annot = Struct.new(:headers_json_value).new(headers.to_json)
      assert Basic.de_output_txt_needs_rebuild?(path, annot)
    end
  end
end
