require 'test_helper'

class BasicH5adV8SelPathTest < ActiveSupport::TestCase
  test 'keeps existing layer naming for plain H5AD selections' do
    assert_nil Basic.h5ad_v8_sel_path(nil)
    assert_equal '/X', Basic.h5ad_v8_sel_path('X')
    assert_equal '/layers/counts', Basic.h5ad_v8_sel_path('counts')
    assert_equal '/raw/X', Basic.h5ad_v8_sel_path('/raw/X')
  end

  test 'archive member selection resolves to /X from preparsing groups' do
    h_prep = {
      'file_path' => '/data/fus/1/filter_feature/Control_filter_feature.h5ad',
      'list_groups' => [{ 'group' => '/layers/counts' }, { 'group' => '/X' }]
    }
    assert_equal '/X',
                 Basic.h5ad_v8_sel_path('filter_feature.h5ad/Control_filter_feature.h5ad', h_prep)
  end

  test 'archive member selection uses the single group when /X is absent' do
    h_prep = { 'file_path' => '/x/a.h5ad', 'list_groups' => [{ 'group' => 'raw/X' }] }
    assert_equal '/raw/X', Basic.h5ad_v8_sel_path('dir/a.h5ad', h_prep)
  end

  test 'archive member selection without usable groups lets parse.v8.py pick' do
    assert_nil Basic.h5ad_v8_sel_path('dir/a.h5ad')
  end

  test 'basename match with preparsed file is treated as archive member' do
    h_prep = { 'file_path' => '/x/sample_matrix', 'list_groups' => [{ 'group' => '/X' }] }
    assert_equal '/X', Basic.h5ad_v8_sel_path('folder/sample_matrix', h_prep)
  end
end
