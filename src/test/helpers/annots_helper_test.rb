# frozen_string_literal: true

require 'test_helper'

class AnnotsHelperTest < ActionView::TestCase
  test 'render_json_foldable builds nested details for objects and arrays' do
    html = render_json_foldable(
      {
        'pipeline_name' => 'ASAP',
        'steps' => [
          { 'step_label' => 'Parsing', 'random_seed' => nil }
        ]
      },
      open: true
    ).to_s

    assert_includes html, 'details'
    assert_includes html, 'pipeline_name'
    assert_includes html, 'steps'
    assert_includes html, 'Parsing'
    assert_includes html, 'null'
    assert_includes html, 'open'
  end

  test 'annot_download_links omits expression matrix TSV and JSON links' do
    annot = Annot.new(id: 42, dim: 3, name: '/matrix')
    html = annot_download_links(annot).to_s

    assert_equal '', html
  end

  test 'annot_download_links marks metadata downloads as nofollow' do
    annot = Annot.new(id: 43, dim: 1, name: '/col_attrs/nCount_RNA')
    html = annot_download_links(annot).to_s

    assert_includes html, 'data-controller="annot-download"'
    assert_includes html, 'rel="nofollow"'
    assert_includes html, 'data-turbo="false"'
    assert_includes html, 'annot-download#start'
    assert_includes html, 'TSV'
    assert_includes html, 'JSON'
    refute_includes html, 'data-annot-download-heavy-value'
  end

  test 'render_json_foldable renders scalars without details' do
    html = render_json_foldable('hello', key: 'title').to_s
    assert_includes html, 'title:'
    assert_includes html, 'hello'
    refute_includes html, '<details'
  end
end
