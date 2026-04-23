# frozen_string_literal: true

class AddIntroducedInVersionIdToFileFormats < ActiveRecord::Migration[7.0]
  # Formats are mapped to the earliest ASAP version in which they are actually
  # supported by the parsing pipeline:
  #   - v4 Java parser FileType enum: RAW_TEXT, ARCHIVE, COMPRESSED,
  #     ARCHIVE_COMPRESSED, H5_10x, LOOM
  #   - MEX and RDS are handled for v<8 by Ruby conversions in
  #     Basic.convert_other_formats (mtx_to_h5.R and convert_seurat.R),
  #     so they have been available since v4.
  #   - H5AD was added to the Java parser FileType enum starting at v5; there
  #     is no Ruby-side H5AD-to-LOOM conversion, so v4 projects cannot parse it.
  FORMAT_INTRODUCED_IN = {
    'H5AD' => 5
  }.freeze
  DEFAULT_INTRODUCED_IN = 4

  def up
    unless column_exists?(:file_formats, :introduced_in_version_id)
      add_column :file_formats, :introduced_in_version_id, :integer
    end

    FileFormat.reset_column_information

    FileFormat.where(introduced_in_version_id: nil).find_each do |ff|
      version_id = FORMAT_INTRODUCED_IN.fetch(ff.name.to_s.upcase, DEFAULT_INTRODUCED_IN)
      ff.update_column(:introduced_in_version_id, version_id)
    end
  end

  def down
    if column_exists?(:file_formats, :introduced_in_version_id)
      remove_column :file_formats, :introduced_in_version_id
    end
  end
end
