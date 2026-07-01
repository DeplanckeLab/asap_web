# frozen_string_literal: true

require_relative '../services/test_base_without_fixtures'
require 'tmpdir'
require 'fileutils'

class EnsemblAssembliesLoaderTest < TestBaseWithoutFixtures
  test 'release_numbers_for_scan uses local ensembl genomes releases from 1' do
    with_tmp_ensembl_tree do |base_dir|
      organism = {
        subdomain: 'bacteria',
        ensembl_db_name: 'escherichia_coli',
        latest_ensembl_release: 10
      }
      releases = AsapData::EnsemblAssembliesLoader.release_numbers_for_scan(
        organism,
        [base_dir],
        10
      )

      assert_equal [5, 10], releases
    end
  end

  test 'release_numbers_for_scan does not include vertebrate releases below 54 without local data' do
    with_tmp_ensembl_tree do |base_dir|
      organism = {
        subdomain: 'vertebrates',
        ensembl_db_name: 'homo_sapiens',
        latest_ensembl_release: 60
      }
      releases = AsapData::EnsemblAssembliesLoader.release_numbers_for_scan(
        organism,
        [base_dir],
        60
      )

      assert_equal [54, 60], releases
      refute_includes releases, 5
    end
  end

  test 'release_numbers_for_scan includes missing releases when download_missing is true' do
    with_tmp_ensembl_tree do |base_dir|
      organism = {
        subdomain: 'bacteria',
        ensembl_db_name: 'escherichia_coli',
        latest_ensembl_release: 10
      }
      releases = AsapData::EnsemblAssembliesLoader.release_numbers_for_scan(
        organism,
        [base_dir],
        10,
        download_missing: true
      )

      assert_equal (5..10).to_a, releases
    end
  end

  test 'release_numbers_for_scan respects ENSEMBL_RELEASE_FROM and ENSEMBL_RELEASE_TO' do
    with_tmp_ensembl_tree do |base_dir|
      organism = {
        subdomain: 'bacteria',
        ensembl_db_name: 'escherichia_coli',
        latest_ensembl_release: 10
      }
      with_env('ENSEMBL_RELEASE_FROM' => '6', 'ENSEMBL_RELEASE_TO' => '9') do
        releases = AsapData::EnsemblAssembliesLoader.release_numbers_for_scan(
          organism,
          [base_dir],
          10
        )

        assert_empty releases
      end
    end
  end

  test 'organisms_in_release_dir lists directories and tgz archives' do
    with_tmp_ensembl_tree do |base_dir|
      names = AsapData::EnsemblAssembliesLoader.organisms_in_release_dir(base_dir + 'bacteria/5')

      assert_includes names, 'escherichia_coli'
    end
  end

  test 'writable_organism_dir prefers writable release tree' do
    with_tmp_ensembl_tree do |base_dir|
      dir = AsapData::EnsemblAssembliesLoader.writable_organism_dir(
        [base_dir],
        :bacteria,
        5,
        'escherichia_coli'
      )

      assert_equal base_dir + 'bacteria/5/escherichia_coli', dir
      assert dir.directory?
    end
  end

  test 'all_ensembl_base_dirs uses only the first existing candidate by default' do
    Dir.mktmpdir('ensembl_loader_primary_') do |primary|
      Dir.mktmpdir('ensembl_loader_secondary_') do |secondary|
        with_env(
          'ENSEMBL_DATA_DIR' => primary,
          'ENSEMBL_MERGE_DATA_DIRS' => nil
        ) do
          dirs = AsapData::EnsemblAssembliesLoader.all_ensembl_base_dirs

          assert_equal [Pathname.new(primary)], dirs
          refute_includes dirs.map(&:to_s), secondary
        end
      end
    end
  end

  test 'all_ensembl_base_dirs merges candidates when ENSEMBL_MERGE_DATA_DIRS is true' do
    Dir.mktmpdir('ensembl_loader_merge_a_') do |first|
      Dir.mktmpdir('ensembl_loader_merge_b_') do |second_parent|
        second = File.join(second_parent, 'ensembl')
        FileUtils.mkdir_p(second)
        with_env(
          'ENSEMBL_DATA_DIR' => first,
          'PROD_DATA_DIR' => second_parent,
          'ENSEMBL_MERGE_DATA_DIRS' => 'true'
        ) do
          dirs = AsapData::EnsemblAssembliesLoader.all_ensembl_base_dirs

          assert_includes dirs.map(&:to_s), first
          assert_includes dirs.map(&:to_s), second
        end
      end
    end
  end

  test 'writable_ensembl_base_dir prefers /mnt/asap_data/ensembl when present' do
    with_tmp_ensembl_tree do |base_dir|
      mnt_dir = Pathname.new(AsapData::EnsemblAssembliesLoader::DEFAULT_ENSEMBL_DATA_DIR)
      skip 'mnt ensembl dir not mounted' unless mnt_dir.directory?

      chosen = AsapData::EnsemblAssembliesLoader.writable_ensembl_base_dir([base_dir, mnt_dir])

      assert_equal mnt_dir, chosen
    end
  end

  test 'scan_missing_meta_coord_entries lists only organisms without meta or coord files' do
    with_tmp_ensembl_tree do |base_dir|
      complete_dir = base_dir + 'bacteria/5/escherichia_coli'
      File.write(complete_dir + 'meta.txt', "42\t1\tassembly.name\tASM\n")
      File.write(complete_dir + 'coord_system.txt', "1\t1\tprimary_assembly\tASM\t1\tdefault_version\n")

      missing_dir = base_dir + 'bacteria/10/escherichia_coli'
      FileUtils.mkdir_p(missing_dir)

      with_env('ENSEMBL_DB_TYPES' => 'bacteria', 'ENSEMBL_RELEASE_TO' => '10') do
        scan = AsapData::EnsemblAssembliesLoader.scan_missing_meta_coord_entries([base_dir])

        assert_equal 2, scan[:organisms_checked]
        assert_equal 1, scan[:already_complete]
        assert_equal 1, scan[:missing].size
        entry = scan[:missing].first
        assert_equal :bacteria, entry.db_type
        assert_equal 10, entry.release_num
        assert_equal 'escherichia_coli', entry.db_name
        assert entry.need_meta
        assert entry.need_coord
      end
    end
  end

  test 'local_meta_txt_present uses file existence without parsing assembly name' do
    Dir.mktmpdir do |tmpdir|
      path = Pathname(tmpdir) + "meta.txt"
      File.write(path, "not a valid ensembl meta row\n")

      assert AsapData::EnsemblAssembliesLoader.local_meta_txt_present?(path)
      refute AsapData::EnsemblAssembliesLoader.valid_meta_file?(path)
    end
  end

  test 'parse_assembly_name handles non-utf8 bytes in meta.txt' do
    Dir.mktmpdir do |tmpdir|
      meta_path = Pathname.new(tmpdir) + "meta.txt"
      File.binwrite(meta_path, "1\t1\tassembly.default\tSpec\xE9cial\n")

      assert_equal "Specécial", AsapData::EnsemblAssembliesLoader.parse_assembly_name(meta_path)
    end
  end

  private

  def with_tmp_ensembl_tree
    Dir.mktmpdir('ensembl_loader_test_') do |tmpdir|
      base_dir = Pathname.new(tmpdir)
      FileUtils.mkdir_p(base_dir + 'bacteria/5/escherichia_coli')
      FileUtils.mkdir_p(base_dir + 'bacteria/10')
      FileUtils.touch(base_dir + 'bacteria/10/escherichia_coli.tgz')
      FileUtils.mkdir_p(base_dir + 'vertebrates/54/homo_sapiens')
      FileUtils.mkdir_p(base_dir + 'vertebrates/60')
      FileUtils.touch(base_dir + 'vertebrates/60/homo_sapiens.tgz')

      yield base_dir
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
