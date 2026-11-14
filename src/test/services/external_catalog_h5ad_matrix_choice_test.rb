# frozen_string_literal: true

require 'test_helper'

class ExternalCatalogH5adMatrixChoiceTest < ActiveSupport::TestCase
  CHOICE = ExternalCatalog::H5adMatrixChoice

  def choices_for(*specs)
    CHOICE.choices(specs.map { |path, is_count| { 'group' => path, 'nber_rows' => 100, 'nber_cols' => 50, 'is_count' => is_count } })
  end

  test 'SCP3342 layout: CellBender counts are recommended over Cell Ranger counts and a normalized X' do
    choices = choices_for(['/X', 0], ['/layers/raw_count_cellbender', 1], ['/layers/raw_count_cellranger', 1])
    assert CHOICE.ambiguous?(choices)
    assert_equal '/layers/raw_count_cellbender', CHOICE.recommended(choices)
  end

  test '/raw/X makes the file unambiguous and is preferred' do
    choices = choices_for(['/X', 0], ['/raw/X', 1], ['/layers/counts', 1])
    refute CHOICE.ambiguous?(choices)
    assert_equal '/raw/X', CHOICE.recommended(choices)
  end

  test 'a single matrix is not ambiguous' do
    refute CHOICE.ambiguous?(choices_for(['/layers/counts', 1]))
  end

  test 'a layer named counts beats other count-like layers' do
    choices = choices_for(['/layers/raw_count_cellbender', 1], ['/layers/counts', 1], ['/X', 1])
    assert_equal '/layers/counts', CHOICE.recommended(choices)
  end

  test 'an integer X beats velocity layers; a normalized X beats nothing count-like' do
    assert_equal '/X', CHOICE.recommended(choices_for(['/layers/spliced', 1], ['/layers/unspliced', 1], ['/X', 1]))
    assert_equal '/X', CHOICE.recommended(choices_for(['/layers/spliced', 1], ['/layers/unspliced', 1], ['/X', 0]))
  end

  test 'a count-like name holding non-integer values is not treated as counts' do
    choices = choices_for(['/X', 0], ['/layers/logcounts', 0], ['/layers/umi', 1])
    assert_equal '/layers/umi', CHOICE.recommended(choices)
  end

  test 'unknown integer-ness keeps the name-based ranking' do
    assert_equal '/layers/counts', CHOICE.recommended(choices_for(['/X', -1], ['/layers/counts', nil]))
  end

  test 'ties keep file order' do
    assert_equal '/layers/a', CHOICE.recommended(choices_for(['/layers/a', 1], ['/layers/b', 1]))
  end

  test 'choices normalize paths, cast numbers and flags, and drop duplicates' do
    choices = CHOICE.choices(
      [
        { 'group' => 'X', 'nber_rows' => '10', 'nber_cols' => 5, 'is_count' => '1', 'dtype' => 'float32' },
        { 'group' => 'counts' },
        { 'group' => '/X' },
        { 'group' => '' },
        'not a hash'
      ]
    )
    assert_equal(
      [
        { 'path' => '/X', 'nber_rows' => 10, 'nber_cols' => 5, 'is_count' => true, 'dtype' => 'float32' },
        { 'path' => '/layers/counts', 'nber_rows' => nil, 'nber_cols' => nil, 'is_count' => nil, 'dtype' => nil }
      ],
      choices
    )
  end

  test 'no choices, no recommendation' do
    assert_nil CHOICE.recommended([])
    refute CHOICE.ambiguous?([])
  end
end
