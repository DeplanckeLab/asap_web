# frozen_string_literal: true

require 'test_helper'
require 'tmpdir'
require 'fileutils'
require 'ostruct'

class H5DataServiceCellSelectionTest < ActiveSupport::TestCase
  test 'write_cell_selection! reads sidecar metadata after a successful python write' do
    Dir.mktmpdir do |dir|
      loom_path = File.join(dir, 'output.loom')
      File.write(loom_path, 'loom')
      selected_path = File.join(dir, 'selected_cells.json')
      File.write(selected_path, { selected_indices: [1, 3], filtered_out_indices: [0] }.to_json)
      meta = {
        'name' => '/col_attrs/X_umap.sel_1',
        'on' => 'CELL',
        'type' => 'DISCRETE',
        'nber_cols' => 5,
        'nber_rows' => 1,
        'categories' => { '-1' => 1, '0' => 2, '1' => 2 }
      }

      original_lock = H5DataService.method(:run_with_optional_loom_write_lock)
      original_exec = H5DataService.method(:docker_exec_h5_write_python3!)
      H5DataService.define_singleton_method(:run_with_optional_loom_write_lock) do |_path, already_locked: false, &block|
        block.call
      end
      script_seen = nil
      H5DataService.define_singleton_method(:docker_exec_h5_write_python3!) do |*_argv, stdin_data:|
        out_path = _argv[3]
        script_seen = stdin_data
        File.write(out_path, meta.to_json)
        ['OK', '', OpenStruct.new(success?: true)]
      end

      result = H5DataService.write_cell_selection!(loom_path, '/col_attrs/X_umap.sel_1', selected_path)
      assert_equal '/col_attrs/X_umap.sel_1', result['name']
      assert_equal 2, result['categories']['1']
      assert_equal 1, result['categories']['-1']
      assert_includes script_seen, 'filtered_out_indices'
      assert_includes script_seen, "mask[idx] = -1"
    ensure
      H5DataService.define_singleton_method(:run_with_optional_loom_write_lock, original_lock)
      H5DataService.define_singleton_method(:docker_exec_h5_write_python3!, original_exec)
    end
  end

  test 'write_cell_selection! raises the python displayed_error' do
    Dir.mktmpdir do |dir|
      loom_path = File.join(dir, 'output.loom')
      File.write(loom_path, 'loom')
      selected_path = File.join(dir, 'selected_cells.json')
      File.write(selected_path, { selected_indices: [99] }.to_json)

      original_lock = H5DataService.method(:run_with_optional_loom_write_lock)
      original_exec = H5DataService.method(:docker_exec_h5_write_python3!)
      H5DataService.define_singleton_method(:run_with_optional_loom_write_lock) do |_path, already_locked: false, &block|
        block.call
      end
      H5DataService.define_singleton_method(:docker_exec_h5_write_python3!) do |*_argv, stdin_data:|
        out_path = _argv[3]
        File.write(out_path, { displayed_error: 'Cell index 99 is out of range (n=5)' }.to_json)
        ['ERROR', '', OpenStruct.new(success?: false)]
      end

      err = assert_raises(RuntimeError) do
        H5DataService.write_cell_selection!(loom_path, '/col_attrs/X_umap.sel_1', selected_path)
      end
      assert_equal 'Cell index 99 is out of range (n=5)', err.message
    ensure
      H5DataService.define_singleton_method(:run_with_optional_loom_write_lock, original_lock)
      H5DataService.define_singleton_method(:docker_exec_h5_write_python3!, original_exec)
    end
  end
end
