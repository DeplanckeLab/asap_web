# frozen_string_literal: true

require_relative '../services/test_base_without_fixtures'
require 'tmpdir'
require 'fileutils'

class EnsemblEmptyArchiveRepairerTest < TestBaseWithoutFixtures
  test 'find_empty_archives detects empty xref inside tgz when gene is present' do
    with_tmp_ensembl_tree do |base_dir|
      release_dir = base_dir + 'vertebrates/105'
      FileUtils.mkdir_p(release_dir)
      pack_archive(
        release_dir + 'callithrix_jacchus.tgz',
        'callithrix_jacchus',
        'gene.txt' => "1\tgene\n",
        'xref.txt' => '',
        'object_xref.txt' => ''
      )

      with_env('ENSEMBL_DATA_DIR' => base_dir.to_s, 'ENSEMBL_DB_TYPES' => 'vertebrates',
               'ENSEMBL_RELEASE_FROM' => '105', 'ENSEMBL_RELEASE_TO' => '105') do
        findings = AsapData::EnsemblEmptyArchiveRepairer.find_empty_archives!
        assert_equal 1, findings.size
        finding = findings.first
        assert_equal 'callithrix_jacchus', finding.db_name
        assert_equal 105, finding.release_num
        assert_includes finding.empty_tables, 'xref.txt'
        assert_includes finding.empty_tables, 'object_xref.txt'
        assert_includes finding.sources, 'archive'
      end
    end
  end

  test 'find_empty_archives detects empty loose xref beside non-empty gene' do
    with_tmp_ensembl_tree do |base_dir|
      organism_dir = base_dir + 'vertebrates/105/callithrix_jacchus'
      FileUtils.mkdir_p(organism_dir)
      File.write(organism_dir + 'gene.txt', "1\tgene\n")
      File.write(organism_dir + 'xref.txt', '')
      File.write(organism_dir + 'object_xref.txt', "1\tox\n")

      with_env('ENSEMBL_DATA_DIR' => base_dir.to_s, 'ENSEMBL_DB_TYPES' => 'vertebrates',
               'ENSEMBL_RELEASE_FROM' => '105', 'ENSEMBL_RELEASE_TO' => '105') do
        findings = AsapData::EnsemblEmptyArchiveRepairer.find_empty_archives!
        assert_equal 1, findings.size
        assert_equal ['xref.txt'], findings.first.empty_tables
        assert_includes findings.first.sources, 'dir'
      end
    end
  end

  test 'find_empty_archives ignores healthy dumps' do
    with_tmp_ensembl_tree do |base_dir|
      organism_dir = base_dir + 'vertebrates/105/homo_sapiens'
      FileUtils.mkdir_p(organism_dir)
      File.write(organism_dir + 'gene.txt', "1\tgene\n")
      File.write(organism_dir + 'xref.txt', "1\txref\n")
      File.write(organism_dir + 'object_xref.txt', "1\tox\n")

      with_env('ENSEMBL_DATA_DIR' => base_dir.to_s, 'ENSEMBL_DB_TYPES' => 'vertebrates',
               'ENSEMBL_RELEASE_FROM' => '105', 'ENSEMBL_RELEASE_TO' => '105') do
        assert_empty AsapData::EnsemblEmptyArchiveRepairer.find_empty_archives!
      end
    end
  end

  test 'dry_run repair reports findings without downloading' do
    with_tmp_ensembl_tree do |base_dir|
      release_dir = base_dir + 'vertebrates/105'
      FileUtils.mkdir_p(release_dir)
      pack_archive(
        release_dir + 'callithrix_jacchus.tgz',
        'callithrix_jacchus',
        'gene.txt' => "1\tgene\n",
        'xref.txt' => '',
        'object_xref.txt' => ''
      )

      with_env(
        'ENSEMBL_DATA_DIR' => base_dir.to_s,
        'ENSEMBL_DB_TYPES' => 'vertebrates',
        'ENSEMBL_RELEASE_FROM' => '105',
        'ENSEMBL_RELEASE_TO' => '105',
        'DRY_RUN' => 'true',
        'RELOAD_DB' => 'false',
        'RELOAD_GENE_SETS' => 'false'
      ) do
        stats = AsapData::EnsemblEmptyArchiveRepairer.repair!(
          remote_db: 'asap_data_v8',
          dry_run: true,
          reload_db: false,
          reload_gene_sets: false
        )
        assert_equal 1, stats[:findings]
        assert_equal 1, stats[:repaired]
        assert_equal 0, stats[:tables_redownloaded]
        assert_equal ['callithrix_jacchus'], stats[:repaired_db_names]
      end
    end
  end

  private

  def with_tmp_ensembl_tree
    Dir.mktmpdir('ensembl_empty_repair_test_') do |tmpdir|
      yield Pathname.new(tmpdir)
    end
  end

  def pack_archive(archive_path, db_name, files)
    Dir.mktmpdir do |packdir|
      inner = File.join(packdir, db_name)
      FileUtils.mkdir_p(inner)
      files.each do |name, content|
        File.binwrite(File.join(inner, name), content)
      end
      system('tar', '-czf', archive_path.to_s, '-C', packdir, db_name, out: File::NULL)
    end
  end

  def with_env(overrides)
    previous = overrides.keys.index_with { |key| ENV[key] }
    overrides.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each do |key, value|
      if value.nil?
        ENV.delete(key)
      else
        ENV[key] = value
      end
    end
  end
end
