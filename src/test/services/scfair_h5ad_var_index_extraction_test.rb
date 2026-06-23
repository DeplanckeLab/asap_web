# frozen_string_literal: true

require 'fileutils'
require_relative 'test_base_without_fixtures'

class ScfairH5adVarIndexExtractionTest < TestBaseWithoutFixtures
  FIXTURE = Rails.root.join('test/fixtures/files/scfair/var_index_nullable_string_array.h5ad').freeze
  SHARED_PATH = '/data/asap2_test/tmp/scfair_var_index_nullable_string_array.h5ad'
  SCHEMA_FIELD = Scfair::Rules.var_index_schema_field

  test 'extracts var/_index encoded as nullable-string-array' do
    skip 'fixture missing' unless FIXTURE.exist?
    skip 'ASAP run data dir unavailable' unless File.directory?('/data/asap2_test/tmp')

    FileUtils.mkdir_p(File.dirname(SHARED_PATH))
    FileUtils.cp(FIXTURE, SHARED_PATH)

    extract = ScfairMinimalExtractService.new(file_path: SHARED_PATH).extract
    field_values = Scfair::FieldValuesFromExtract.call(extract, format: 'h5ad')
    series = Array(field_values['var/_index#series'])

    assert series.any?, 'expected var/_index#series to be populated'
    assert_includes series, 'ENSG00000186092'
    assert_includes series, 'ERCC-00003'

    index_result = Scfair::VarIndexValidator.new(field_values: field_values, format: 'h5ad').call
    assert_empty index_result[:errors]
    assert index_result[:valid_checks].any? { |c| c[:field] == SCHEMA_FIELD && c[:status] == 'passed' }
  end
end
