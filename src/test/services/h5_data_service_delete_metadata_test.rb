# frozen_string_literal: true

require 'test_helper'
require 'tmpdir'
require 'ostruct'

class H5DataServiceDeleteMetadataTest < ActiveSupport::TestCase
  test 'delete_metadata_datasets! stages stripped paths and requires OK from python' do
    Dir.mktmpdir do |dir|
      loom_path = File.join(dir, 'output.loom')
      File.write(loom_path, 'loom')
      captured = {}

      original_lock = H5DataService.method(:run_with_optional_loom_write_lock)
      original_exec = H5DataService.method(:docker_exec_h5_write_python3!)
      H5DataService.define_singleton_method(:run_with_optional_loom_write_lock) do |_path, already_locked: false, &block|
        block.call
      end
      H5DataService.define_singleton_method(:docker_exec_h5_write_python3!) do |*argv, stdin_data:|
        captured[:argv] = argv
        captured[:stdin] = stdin_data
        captured[:staged] = JSON.parse(File.read(argv[1]))
        ['OK', '', OpenStruct.new(success?: true)]
      end

      assert H5DataService.delete_metadata_datasets!(
        loom_path,
        ['/col_attrs/X_tsne.sel_1', 'col_attrs/X_tsne.sel_2', '/col_attrs/X_tsne.sel_1']
      )
      assert_equal loom_path, captured[:argv][0]
      assert_equal ['col_attrs/X_tsne.sel_1', 'col_attrs/X_tsne.sel_2'], captured[:staged]
      assert_includes captured[:stdin], 'del f[field]'
      assert_empty Dir.glob(File.join(dir, '.asap_delete_metadata_*.json'))
    ensure
      H5DataService.define_singleton_method(:run_with_optional_loom_write_lock, original_lock)
      H5DataService.define_singleton_method(:docker_exec_h5_write_python3!, original_exec)
    end
  end

  test 'delete_metadata_datasets! raises the python error' do
    Dir.mktmpdir do |dir|
      loom_path = File.join(dir, 'output.loom')
      File.write(loom_path, 'loom')

      original_lock = H5DataService.method(:run_with_optional_loom_write_lock)
      original_exec = H5DataService.method(:docker_exec_h5_write_python3!)
      H5DataService.define_singleton_method(:run_with_optional_loom_write_lock) do |_path, already_locked: false, &block|
        block.call
      end
      H5DataService.define_singleton_method(:docker_exec_h5_write_python3!) do |*_argv, stdin_data:|
        ['', 'Unable to open file (File is already open for write)', OpenStruct.new(success?: false)]
      end

      err = assert_raises(RuntimeError) do
        H5DataService.delete_metadata_datasets!(loom_path, ['/col_attrs/X_tsne.sel_3'])
      end
      assert_match(/Unable to open file/, err.message)
    ensure
      H5DataService.define_singleton_method(:run_with_optional_loom_write_lock, original_lock)
      H5DataService.define_singleton_method(:docker_exec_h5_write_python3!, original_exec)
    end
  end

  test 'delete_metadata_datasets! skips docker when there are no paths' do
    called = false
    original_exec = H5DataService.method(:docker_exec_h5_write_python3!)
    H5DataService.define_singleton_method(:docker_exec_h5_write_python3!) do |*_argv, stdin_data:|
      called = true
      ['OK', '', OpenStruct.new(success?: true)]
    end

    assert H5DataService.delete_metadata_datasets!('/tmp/missing.loom', ['', nil])
    refute called
  ensure
    H5DataService.define_singleton_method(:docker_exec_h5_write_python3!, original_exec)
  end
end
