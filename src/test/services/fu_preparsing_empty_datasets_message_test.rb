# frozen_string_literal: true

require 'test_helper'

class FuPreparsingEmptyDatasetsMessageTest < ActiveSupport::TestCase
  setup do
    @fu = Fu.new(upload_file_name: 'input_file.rds')
    @service = FuPreparsingService.new(@fu)
  end

  test 'build_summary promotes preparsing warnings to displayed_error when no datasets' do
    output = {
      'detected_format' => 'RDS',
      'list_groups' => [],
      'warnings' => [
        "WARNING: Skipping assay 'RNA', because it's missing the layer 'counts'. Available layers for assay 'RNA': ['counts.GSE196638_NL1']"
      ]
    }

    summary = @service.send(:build_summary, output)

    assert_equal 0, summary[:dataset_count]
    assert_includes summary[:displayed_error], "missing the layer 'counts'"
    assert_includes summary[:displayed_error], 'counts.GSE196638_NL1'
  end

  test 'collect_warnings includes preparsing output warnings' do
    Dir.mktmpdir do |dir|
      @service.instance_variable_set(:@upload_dir, Pathname.new(dir))
      output = {
        'warnings' => ["WARNING: Skipping assay 'RNA', because it's missing the layer 'counts'."]
      }

      warnings = @service.send(:collect_warnings, output)

      assert warnings.any? { |w| w.to_s.include?("missing the layer 'counts'") }
    end
  end
end
