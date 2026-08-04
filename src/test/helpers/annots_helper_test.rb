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

  test 'render_json_foldable renders scalars without details' do
    html = render_json_foldable('hello', key: 'title').to_s
    assert_includes html, 'title:'
    assert_includes html, 'hello'
    refute_includes html, '<details'
  end
end
