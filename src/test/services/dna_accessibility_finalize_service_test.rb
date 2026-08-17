# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class DnaAccessibilityFinalizeServiceTest < TestBaseWithoutFixtures
  setup do
    @parsing_dir = Pathname.new(Dir.mktmpdir('dna_accessibility'))
  end

  teardown do
    FileUtils.rm_rf(@parsing_dir) if @parsing_dir && @parsing_dir.exist?
  end

  test 'download_assets lists tabix and index relative to parsing' do
    assets = DnaAccessibilityFinalizeService.download_assets(@parsing_dir)
    by_type = assets.index_by { |asset| asset[:upload_type_name] }

    tabix = by_type.fetch('dna_accessibility')
    assert_equal 'parsing/dna_accessibility.tsv.bgz', tabix[:rel_path]
    assert_equal 'DNA accessibility (tabix)', tabix[:label]
    refute tabix[:present]
    assert_equal 0, tabix[:size]

    index = by_type.fetch('dna_accessibility_tbi')
    assert_equal 'parsing/dna_accessibility.tsv.bgz.tbi', index[:rel_path]
    assert_equal 'DNA accessibility index', index[:label]
    refute index[:present]
    assert_equal 0, index[:size]
  end

  test 'download_assets reports present files and sizes' do
    fragments = @parsing_dir.join('dna_accessibility.tsv.bgz')
    tbi = @parsing_dir.join('dna_accessibility.tsv.bgz.tbi')
    File.write(fragments, 'fragments')
    File.write(tbi, 'index')

    assets = DnaAccessibilityFinalizeService.download_assets(@parsing_dir)
    by_type = assets.index_by { |asset| asset[:upload_type_name] }

    assert by_type.fetch('dna_accessibility')[:present]
    assert_equal File.size(fragments), by_type.fetch('dna_accessibility')[:size]
    assert by_type.fetch('dna_accessibility_tbi')[:present]
    assert_equal File.size(tbi), by_type.fetch('dna_accessibility_tbi')[:size]
    assert DnaAccessibilityFinalizeService.assets_present?(@parsing_dir)
  end

  test 'assets_present is false when only one asset exists' do
    File.write(@parsing_dir.join('dna_accessibility.tsv.bgz'), 'fragments')

    refute DnaAccessibilityFinalizeService.assets_present?(@parsing_dir)
  end
end
