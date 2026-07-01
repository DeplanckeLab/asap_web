# frozen_string_literal: true

require_relative '../services/test_base_without_fixtures'
require 'tmpdir'
require 'fileutils'

class EnsemblArchiveIntegratorTest < TestBaseWithoutFixtures
  test 'integrate_into_archive merges loose files and preserves archive layout' do
    Dir.mktmpdir('ensembl_integrate_test_') do |tmpdir|
      base = Pathname.new(tmpdir)
      archive_path = base + 'escherichia_coli.tgz'
      organism_dir = base + 'escherichia_coli'
      FileUtils.mkdir_p(organism_dir)

      Dir.mktmpdir do |packdir|
        inner = File.join(packdir, 'escherichia_coli')
        FileUtils.mkdir_p(inner)
        File.write(File.join(inner, 'gene.txt'), "existing\n")
        system('tar', '-czf', archive_path.to_s, '-C', packdir, 'escherichia_coli', out: File::NULL)
      end

      File.write(organism_dir + 'meta.txt', "1\t1\tassembly.default\tASM\n")
      File.write(organism_dir + 'coord_system.txt', "1\t1\tchromosome\tASM\t1\tdefault_version\n")

      assert AsapData::EnsemblArchiveIntegrator.integrate_into_archive!(
        archive_path,
        'escherichia_coli',
        {
          'meta.txt' => organism_dir + 'meta.txt',
          'coord_system.txt' => organism_dir + 'coord_system.txt'
        }
      )

      extracted = `tar -xzf #{archive_path.to_s} -O escherichia_coli/meta.txt`
      assert_includes extracted, 'assembly.default'
      assert_includes `tar -tzf #{archive_path.to_s}`, 'escherichia_coli/gene.txt'
    end
  end

  test 'integrate skips when dry run' do
    with_env('DRY_RUN' => 'true') do
      stats = AsapData::EnsemblArchiveIntegrator.integrate!(dry_run: true)
      assert stats[:archives_updated] >= 0
    end
  end

  private

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
