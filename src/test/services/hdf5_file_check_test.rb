# frozen_string_literal: true

require 'test_helper'
require 'tmpdir'
require 'fileutils'

class Hdf5FileCheckTest < ActiveSupport::TestCase
  test 'builds an incomplete-file message from an HDF5 truncated OSError' do
    text = 'OSError: Unable to synchronously open file (truncated file: eof = 17627398144, sblock->base_addr = 0, stored_eof = 33219989200)'
    message = Hdf5FileCheck.truncated_message(text)

    assert_includes message, '17627398144'
    assert_includes message, '33219989200'
    assert_includes message, 'incomplete'
  end

  test 'returns nil when the text is not an HDF5 truncation error' do
    assert_nil Hdf5FileCheck.truncated_message('File format not detected.')
  end

  test 'builds a corrupt-file message from inflate and B-tree errors' do
    inflate = Hdf5FileCheck.user_message("OSError: Can't synchronously read data (inflate() failed)")
    btree = Hdf5FileCheck.user_message("OSError: Can't synchronously read data (wrong B-tree signature)")

    assert_includes inflate, 'corrupted'
    assert_includes btree, 'corrupted'
    assert_nil Hdf5FileCheck.user_message('File format not detected.')
  end
end
