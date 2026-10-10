# frozen_string_literal: true

require 'test_helper'
require 'tmpdir'

class PythonParseFailureMessageTest < ActiveSupport::TestCase
  test 'prefers ErrorJSON displayed_error over rpy2 console stdout' do
    Dir.mktmpdir do |dir|
      output_json = File.join(dir, 'output.json')
      File.write(
        output_json,
        {
          displayed_error:
            "Assay 'RNA' does not contain retrievable 'counts' data (checked both the Seurat v5 'counts' layer and the v4 'counts' slot)."
        }.to_json
      )

      message = PythonParseFailureMessage.displayed_error(
        output_json_path: output_json,
        parse_stdout: "R callback write-console: Loading required namespace: SeuratObject\n  \n",
        exitstatus: 1,
        preparsing_warnings: ["WARNING: Skipping assay 'RNA', because it's missing the layer 'counts'."]
      )

      assert_includes message, "does not contain retrievable 'counts'"
      refute_includes message, 'R callback write-console'
    end
  end

  test 'falls back to preparsing warnings when stdout is only rpy2 console noise' do
    message = PythonParseFailureMessage.displayed_error(
      output_json_path: '/nonexistent/output.json',
      parse_stdout: "R callback write-console: Loading required namespace: SeuratObject\n",
      exitstatus: 1,
      preparsing_warnings: [
        "WARNING: Skipping assay 'RNA', because it's missing the layer 'counts'. Available layers for assay 'RNA': ['counts.GSE196638_NL1']"
      ]
    )

    assert_includes message, "missing the layer 'counts'"
    assert_includes message, 'counts.GSE196638_NL1'
    refute_includes message, 'R callback write-console'
  end

  test 'keeps HDF5 truncation mapping from Hdf5FileCheck' do
    raw = 'OSError: Unable to synchronously open file (truncated file: eof = 10, sblock->base_addr = 0, stored_eof = 99)'
    message = PythonParseFailureMessage.displayed_error(
      output_json_path: nil,
      parse_stdout: raw,
      exitstatus: 1
    )

    assert_includes message, 'incomplete'
  end
end
