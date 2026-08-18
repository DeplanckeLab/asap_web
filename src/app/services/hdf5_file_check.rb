# frozen_string_literal: true

# Turns HDF5 library errors from truncated or overlapping downloads into a
# user-facing incomplete/corrupt file message.
class Hdf5FileCheck
  TRUNCATED_RE = /truncated file: eof = (\d+).*stored_eof = (\d+)/i.freeze

  def self.user_message(text)
    truncated_message(text) || corrupted_message(text)
  end

  def self.truncated_message(text)
    match = TRUNCATED_RE.match(text.to_s)
    return nil unless match

    actual = match[1].to_i
    expected = match[2].to_i
    "The H5AD file is incomplete: #{actual} bytes on disk, HDF5 header expects #{expected} bytes. " \
      "The download was interrupted or is still running. Wait until the download finishes, then reset parsing."
  end

  def self.corrupted_message(text)
    downcased = text.to_s.downcase
    return nil unless downcased.include?('inflate() failed') || downcased.include?('wrong b-tree signature')

    'The H5AD file is corrupted (HDF5 gzip/B-tree data cannot be read). ' \
      'This happens when a download was interrupted or two downloads wrote the same file. ' \
      'Delete the upload and download the file again.'
  end
end
