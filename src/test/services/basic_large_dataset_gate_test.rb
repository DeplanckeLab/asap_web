# frozen_string_literal: true

require 'test_helper'

class BasicLargeDatasetGateTest < ActiveSupport::TestCase
  setup do
    @prev_env = ENV['ASAP_LARGE_DATASET_MIN_CELLS']
  end

  teardown do
    if @prev_env.nil?
      ENV.delete('ASAP_LARGE_DATASET_MIN_CELLS')
    else
      ENV['ASAP_LARGE_DATASET_MIN_CELLS'] = @prev_env
    end
  end

  test 'large_dataset_min_cells defaults to 100000 when ENV unset' do
    ENV.delete('ASAP_LARGE_DATASET_MIN_CELLS')
    assert_equal 100_000, Basic.large_dataset_min_cells
  end

  test 'large_dataset_min_cells reads positive ENV integer' do
    ENV['ASAP_LARGE_DATASET_MIN_CELLS'] = '50000'
    assert_equal 50_000, Basic.large_dataset_min_cells
  end

  test 'large_dataset_min_cells falls back on blank or invalid ENV' do
    ENV['ASAP_LARGE_DATASET_MIN_CELLS'] = ''
    assert_equal 100_000, Basic.large_dataset_min_cells
    ENV['ASAP_LARGE_DATASET_MIN_CELLS'] = 'nope'
    assert_equal 100_000, Basic.large_dataset_min_cells
    ENV['ASAP_LARGE_DATASET_MIN_CELLS'] = '0'
    assert_equal 100_000, Basic.large_dataset_min_cells
  end

  test 'large_dataset? uses ENV threshold' do
    ENV['ASAP_LARGE_DATASET_MIN_CELLS'] = '100'
    assert_not Basic.large_dataset?(99)
    assert Basic.large_dataset?(100)
    assert Basic.large_dataset?(101)
  end

  test 'method_allowed_for_large_dataset? allows all methods below threshold' do
    ENV['ASAP_LARGE_DATASET_MIN_CELLS'] = '100000'
    step = Step.new(name: 'scaling', attrs_json: '{}')
    method = StdMethod.new(name: 'seurat', step_id: nil, obj_attrs_json: '{}')
    method.define_singleton_method(:step) { step }

    assert Basic.method_allowed_for_large_dataset?(method, 99_999)
  end

  test 'method_allowed_for_large_dataset? allows step flagged large_dataset_ok' do
    ENV['ASAP_LARGE_DATASET_MIN_CELLS'] = '100000'
    step = Step.new(
      name: 'cell_filtering',
      attrs_json: JSON.generate(Basic::LARGE_DATASET_OK_ATTR => true)
    )
    method = StdMethod.new(name: 'qc_plots', obj_attrs_json: '{}')
    method.define_singleton_method(:step) { step }

    assert Basic.method_allowed_for_large_dataset?(method, 200_000)
  end

  test 'method_allowed_for_large_dataset? allows method flagged large_dataset_ok' do
    ENV['ASAP_LARGE_DATASET_MIN_CELLS'] = '100000'
    step = Step.new(name: 'de', attrs_json: '{}')
    method = StdMethod.new(
      name: 't_test_approx',
      obj_attrs_json: JSON.generate(Basic::LARGE_DATASET_OK_ATTR => true)
    )
    method.define_singleton_method(:step) { step }

    assert Basic.method_allowed_for_large_dataset?(method, 200_000)
  end

  test 'method_allowed_for_large_dataset? blocks unflagged methods above threshold' do
    ENV['ASAP_LARGE_DATASET_MIN_CELLS'] = '100000'
    step = Step.new(name: 'scaling', attrs_json: '{}')
    method = StdMethod.new(name: 'seurat', obj_attrs_json: '{}')
    method.define_singleton_method(:step) { step }

    assert_not Basic.method_allowed_for_large_dataset?(method, 200_000)
  end

  test 'large_dataset_block_message includes threshold and selected cell count' do
    ENV['ASAP_LARGE_DATASET_MIN_CELLS'] = '100000'
    msg = Basic.large_dataset_block_message(370_115)
    assert_match(/100000/, msg)
    assert_match(/370115/, msg)
    assert_match(/selected input/i, msg)
    assert_match(/cell filtering/i, msg)
    assert_match(/Approximate t-test/i, msg)
  end

  test 'large_dataset_analysis_notice refers to current uploaded dataset' do
    ENV['ASAP_LARGE_DATASET_MIN_CELLS'] = '100000'
    msg = Basic.large_dataset_analysis_notice(370_115)
    assert_match(/100000/, msg)
    assert_match(/370115/, msg)
    assert_match(/current uploaded dataset/i, msg)
    assert_no_match(/selected input/i, msg)
    assert_match(/cell filtering/i, msg)
  end

  test 'input_matrix_nber_cols_from_attrs_or_payload reads payload nber_cols' do
    h = {
      'input_matrix' => {
        'annot_id' => 1,
        'nber_cols' => 12345
      }
    }
    assert_equal 12_345, Basic.input_matrix_nber_cols_from_attrs_or_payload(h)
  end

  test 'annot_large_dataset? uses nber_cols when cells axis is greater than 1' do
    ENV['ASAP_LARGE_DATASET_MIN_CELLS'] = '100000'
    small = Struct.new(:nber_cols, :nber_rows).new(50_000, 20_000)
    large = Struct.new(:nber_cols, :nber_rows).new(200_000, 20_000)
    row_meta = Struct.new(:nber_cols, :nber_rows).new(1, 20_000)
    assert_not Basic.annot_large_dataset?(small)
    assert Basic.annot_large_dataset?(large)
    assert_not Basic.annot_large_dataset?(row_meta)
  end

  test 'json_flag_true? accepts boolean and string forms' do
    assert Basic.json_flag_true?(true)
    assert Basic.json_flag_true?('true')
    assert Basic.json_flag_true?('1')
    assert_not Basic.json_flag_true?(false)
    assert_not Basic.json_flag_true?('false')
    assert_not Basic.json_flag_true?(nil)
  end
end
