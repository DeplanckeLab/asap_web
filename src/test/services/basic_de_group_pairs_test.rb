# frozen_string_literal: true

require 'test_helper'

class BasicDeGroupPairsTest < ActiveSupport::TestCase
  test 'flatten_de_group_pairs! expands a single pair into group_ref and group_comp' do
    h = { 'group_pairs' => ['0', ''], 'all_against_compl' => 'true' }
    Basic.flatten_de_group_pairs!(h)
    assert_equal '0', h['group_ref']
    assert_equal '', h['group_comp']
    assert_nil h['group_pairs']
  end

  test 'flatten_de_group_pairs! raises when list of pairs was not expanded' do
    h = {
      'group_pairs' => [['0', ''], ['1', '']],
      'all_against_compl' => 'true'
    }
    err = assert_raises(StandardError) { Basic.flatten_de_group_pairs!(h) }
    assert_match(/not expanded into combinatorial runs/, err.message)
  end

  test 'flatten_de_group_pairs! is a no-op without group_pairs' do
    h = { 'group_ref' => '0', 'group_comp' => '1' }
    Basic.flatten_de_group_pairs!(h)
    assert_equal '0', h['group_ref']
    assert_equal '1', h['group_comp']
  end
end
