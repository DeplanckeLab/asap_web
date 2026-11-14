# frozen_string_literal: true

require 'test_helper'
require 'minitest/mock'

class H5DataServiceDockerExecTimeoutTest < ActiveSupport::TestCase
  test 'docker_exec_h5_python3! kills process group and raises on timeout' do
    fake_wait = Object.new
    def fake_wait.pid
      42_424
    end

    joined_after_kill = false
    fake_wait.define_singleton_method(:join) do |timeout = nil|
      if timeout.nil? || timeout >= 10
        joined_after_kill = true
        true
      else
        false
      end
    end
    fake_wait.define_singleton_method(:alive?) { !joined_after_kill }
    fake_wait.define_singleton_method(:value) { Struct.new(:success?).new(false) }

    stdin = StringIO.new
    def stdin.close; end
    stdout = StringIO.new('')
    stderr = StringIO.new('')

    Open3.stub(:popen3, lambda { |*_args, **_kwargs, &block|
      block.call(stdin, stdout, stderr, fake_wait)
    }) do
      killed = []
      Process.stub(:kill, ->(sig, pid) { killed << [sig, pid] }) do
        Process.stub(:getpgid, ->(_pid) { raise Errno::ESRCH }) do
          err = assert_raises(Timeout::Error) do
            H5DataService.docker_exec_h5_python3!('arg', stdin_data: 'print(1)', timeout_seconds: 1)
          end
          assert_match(/timed out after 1s/, err.message)
          assert(killed.any? { |sig, pid| pid == 42_424 && sig.to_s.include?('TERM') })
        end
      end
    end
  end

  test 'docker_exec_h5_write_python3! delegates with HDF5 locking and the lock-wait prelude' do
    called = nil
    H5DataService.stub(
      :docker_exec_h5_python3!,
      lambda { |*argv, stdin_data:, timeout_seconds:, hdf5_locking:|
        called = [argv, stdin_data, timeout_seconds, hdf5_locking]
        ['OK', '', Struct.new(:success?).new(true)]
      }
    ) do
      out, _err, status = H5DataService.docker_exec_h5_write_python3!(
        'a', 'b', stdin_data: 'x', timeout_seconds: 300
      )
      assert_equal 'OK', out
      assert status.success?
      argv, stdin_data, timeout_seconds, hdf5_locking = called
      assert_equal ['a', 'b'], argv
      assert_equal 300, timeout_seconds
      assert_equal true, hdf5_locking
      assert stdin_data.end_with?("\nx"), 'caller script must follow the prelude'
      assert_includes stdin_data, '_asap_h5py.File = _AsapLockWaitFile'
      assert_includes stdin_data, '_asap_time.monotonic() + 240'
    end
  end

  test 'reads disable HDF5 locking, writes keep it' do
    envs = []
    ok_wait = Object.new
    ok_wait.define_singleton_method(:pid) { 1 }
    ok_wait.define_singleton_method(:join) { |_timeout = nil| true }
    ok_wait.define_singleton_method(:alive?) { false }
    ok_wait.define_singleton_method(:value) { Struct.new(:success?).new(true) }
    stdin = StringIO.new
    def stdin.close; end

    Open3.stub(:popen3, lambda { |*cmd, **_kwargs, &block|
      envs << cmd[cmd.index('-e') + 1]
      block.call(stdin, StringIO.new('OK'), StringIO.new(''), ok_wait)
    }) do
      H5DataService.docker_exec_h5_python3!('p', stdin_data: 'print(1)')
      H5DataService.docker_exec_h5_write_python3!('p', stdin_data: 'print(1)')
    end
    assert_equal ['HDF5_USE_FILE_LOCKING=FALSE', 'HDF5_USE_FILE_LOCKING=TRUE'], envs
  end
end
