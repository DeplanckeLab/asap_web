# frozen_string_literal: true

require_relative 'test_base_without_fixtures'
require 'fileutils'
require 'json'
require 'tmpdir'

class ScfairProjectEnsemblMetadataResolverTest < TestBaseWithoutFixtures
  VersionStub = Struct.new(:env_data, keyword_init: true)
  OrganismStub = Struct.new(:tax_id, :ensembl_subdomain_id, :ensembl_subdomain, keyword_init: true)
  SubdomainStub = Struct.new(:name, keyword_init: true)
  ProjectStub = Struct.new(:organism, :version_for_catalog, :storage_dir, keyword_init: true)

  def build_project(organism:, tool_versions:, remote_db: 'asap_data_v8', storage_dir: nil)
    version = VersionStub.new(
      env_data: {
        'tool_versions' => tool_versions,
        'asap_data_db_name' => remote_db
      }
    )
    ProjectStub.new(organism: organism, version_for_catalog: version, storage_dir: storage_dir)
  end

  test 'resolves vertebrate ensembl metadata from version and organism' do
    organism = OrganismStub.new(
      tax_id: 9606,
      ensembl_subdomain_id: 1,
      ensembl_subdomain: SubdomainStub.new(name: 'vertebrates')
    )
    project = build_project(
      organism: organism,
      tool_versions: { 'ensembl_vertebrate' => '113', 'ensembl_genomes' => '60' }
    )

    lookup = Minitest::Mock.new
    lookup.expect(:remote_available?, true)
    lookup.expect(:assembly_name_at_release_for_organism, 'GRCh38.p14', [9606, '113'])
    lookup.expect(:genome_browser_assembly, 'GRCh38.p14', [{ tax_id: 9606, assembly_name: 'GRCh38.p14', release: '113' }])

    result = Scfair::ProjectEnsemblMetadataResolver.call(project, lookup: lookup)

    assert_equal '113', result[:ensembl_release]
    assert_equal 'Ensembl', result[:ensembl_database]
    assert_equal 'GRCh38.p14', result[:ensembl_assembly]
    assert_equal 'GRCh38.p14', result[:ensembl_genome_browser_assembly]
    lookup.verify
  end

  test 'resolves metazoa ensembl metadata using ensembl_genomes release' do
    organism = OrganismStub.new(
      tax_id: 7227,
      ensembl_subdomain_id: 2,
      ensembl_subdomain: SubdomainStub.new(name: 'metazoa')
    )
    project = build_project(
      organism: organism,
      tool_versions: { 'ensembl_vertebrate' => '113', 'ensembl_genomes' => '60' }
    )

    lookup = Minitest::Mock.new
    lookup.expect(:remote_available?, true)
    lookup.expect(:assembly_name_at_release_for_organism, 'BDGP6.46', [7227, '60'])
    lookup.expect(:genome_browser_assembly, 'BDGP6.46', [{ tax_id: 7227, assembly_name: 'BDGP6.46', release: '60' }])

    result = Scfair::ProjectEnsemblMetadataResolver.call(project, lookup: lookup)

    assert_equal '60', result[:ensembl_release]
    assert_equal 'EnsemblMetazoa', result[:ensembl_database]
    assert_equal 'BDGP6.46', result[:ensembl_assembly]
    assert_equal 'BDGP6.46', result[:ensembl_genome_browser_assembly]
    lookup.verify
  end

  test 'resolves COVID-19 database and release' do
    organism = OrganismStub.new(
      tax_id: 2697049,
      ensembl_subdomain_id: 3,
      ensembl_subdomain: SubdomainStub.new(name: 'viruses')
    )
    project = build_project(
      organism: organism,
      tool_versions: { 'ensembl_genomes' => '60' }
    )

    lookup = Minitest::Mock.new
    lookup.expect(:remote_available?, true)
    lookup.expect(:assembly_name_at_release_for_organism, 'GCA_009858895.3', [2697049, '60'])

    result = Scfair::ProjectEnsemblMetadataResolver.call(project, lookup: lookup)

    assert_equal '60', result[:ensembl_release]
    assert_equal 'EnsemblCOVID-19', result[:ensembl_database]
    assert_equal 'GCA_009858895.3', result[:ensembl_assembly]
    assert_equal 'GCA_009858895.3', result[:ensembl_genome_browser_assembly]
    lookup.verify
  end


  test 'prefers probable Ensembl release and assembly from parsing output.json' do
    organism = OrganismStub.new(
      tax_id: 10090,
      ensembl_subdomain_id: 1,
      ensembl_subdomain: SubdomainStub.new(name: 'vertebrates')
    )
    dir = Dir.mktmpdir('scfair-ensembl-parsing')
    FileUtils.mkdir_p(File.join(dir, 'parsing'))
    File.write(
      File.join(dir, 'parsing', 'output.json'),
      {
        messages: [
          "Estimated Ensembl release 100 (earliest release consistent with the most gene IDs: 10/10 genes co-exist there), assembly 'GRCm38.p6'. This is an estimate from gene-ID coverage, not a recorded provenance."
        ]
      }.to_json
    )
    project = build_project(
      organism: organism,
      tool_versions: { 'ensembl_vertebrate' => '116' },
      storage_dir: dir
    )

    lookup = Minitest::Mock.new
    lookup.expect(:remote_available?, true)
    lookup.expect(:genome_browser_assembly, 'GRCm38.p6', [{ tax_id: 10090, assembly_name: 'GRCm38.p6', release: '100' }])

    result = Scfair::ProjectEnsemblMetadataResolver.call(project, lookup: lookup)

    assert_equal '100', result[:ensembl_release]
    assert_equal 'GRCm38.p6', result[:ensembl_assembly]
    assert_equal 'GRCm38.p6', result[:ensembl_genome_browser_assembly]
    assert_equal 'Ensembl', result[:ensembl_database]
    assert_equal :parsing, result[:source]
  ensure
    FileUtils.remove_entry(dir) if dir && Dir.exist?(dir)
  end

  test 'prefers ensembl_assembly from Annot list_cat_json over parsing and remote lookup' do
    organism = OrganismStub.new(
      tax_id: 10090,
      ensembl_subdomain_id: 1,
      ensembl_subdomain: SubdomainStub.new(name: 'vertebrates')
    )
    dir = Dir.mktmpdir('scfair-ensembl-annot')
    FileUtils.mkdir_p(File.join(dir, 'parsing'))
    File.write(
      File.join(dir, 'parsing', 'output.json'),
      {
        messages: [
          "Estimated Ensembl release 100 (earliest release consistent with the most gene IDs: 10/10 genes co-exist there), assembly 'GRCm38.p6'."
        ]
      }.to_json
    )

    annot = Struct.new(:id, :name, :filepath, :list_cat_json, :categories_json, keyword_init: true).new(
      id: 1,
      name: '/attrs/ensembl_assembly',
      filepath: 'parsing/output.loom',
      list_cat_json: ['GCA_002204515.1'].to_json,
      categories_json: nil
    )
    project = build_project(
      organism: organism,
      tool_versions: { 'ensembl_vertebrate' => '116' },
      storage_dir: dir
    )
    project.define_singleton_method(:annots) { [annot] }

    result = Scfair::ProjectEnsemblMetadataResolver.call(project, lookup: Object.new)

    assert_equal 'GCA_002204515.1', result[:ensembl_assembly]
    assert_equal 'GCA_002204515.1', result[:ensembl_genome_browser_assembly]
    assert_equal :annot, result[:source]
  ensure
    FileUtils.remove_entry(dir) if dir && Dir.exist?(dir)
  end

  test 'reads ensembl_assembly from parsing output.json metadata categories' do
    organism = OrganismStub.new(
      tax_id: 10090,
      ensembl_subdomain_id: 1,
      ensembl_subdomain: SubdomainStub.new(name: 'vertebrates')
    )
    dir = Dir.mktmpdir('scfair-ensembl-meta')
    FileUtils.mkdir_p(File.join(dir, 'parsing'))
    File.write(
      File.join(dir, 'parsing', 'output.json'),
      {
        metadata: [
          {
            name: '/attrs/ensembl_assembly',
            categories: { 'GCA_002204515.1' => 1 }
          },
          {
            name: '/attrs/ensembl_release',
            categories: { '60' => 1 }
          }
        ]
      }.to_json
    )
    project = build_project(
      organism: organism,
      tool_versions: { 'ensembl_vertebrate' => '116' },
      storage_dir: dir
    )

    result = Scfair::ProjectEnsemblMetadataResolver.call(project, lookup: Object.new)

    assert_equal '60', result[:ensembl_release]
    assert_equal 'GCA_002204515.1', result[:ensembl_assembly]
    assert_equal 'GCA_002204515.1', result[:ensembl_genome_browser_assembly]
    assert_equal :parsing, result[:source]
  ensure
    FileUtils.remove_entry(dir) if dir && Dir.exist?(dir)
  end

  test 'resolves genome browser assembly from INSDC accession when loom stores assembly name' do
    organism = OrganismStub.new(
      tax_id: 7159,
      ensembl_subdomain_id: 2,
      ensembl_subdomain: SubdomainStub.new(name: 'metazoa')
    )
    dir = Dir.mktmpdir('scfair-ensembl-aedes')
    FileUtils.mkdir_p(File.join(dir, 'parsing'))
    File.write(
      File.join(dir, 'parsing', 'output.json'),
      {
        metadata: [
          { name: '/attrs/ensembl_assembly', categories: { 'AaegL5' => 1 } },
          { name: '/attrs/ensembl_release', categories: { '62' => 1 } }
        ]
      }.to_json
    )
    project = build_project(
      organism: organism,
      tool_versions: { 'ensembl_genomes' => '62' },
      storage_dir: dir
    )

    lookup = Minitest::Mock.new
    lookup.expect(:remote_available?, true)
    lookup.expect(:genome_browser_assembly, 'GCA_002204515.1', [{ tax_id: 7159, assembly_name: 'AaegL5', release: '62' }])

    result = Scfair::ProjectEnsemblMetadataResolver.call(project, lookup: lookup)

    assert_equal '62', result[:ensembl_release]
    assert_equal 'AaegL5', result[:ensembl_assembly]
    assert_equal 'GCA_002204515.1', result[:ensembl_genome_browser_assembly]
    lookup.verify
  ensure
    FileUtils.remove_entry(dir) if dir && Dir.exist?(dir)
  end

  test 'uses GCA accession directly as genome browser assembly when already stored in loom' do
    organism = OrganismStub.new(
      tax_id: 7159,
      ensembl_subdomain_id: 2,
      ensembl_subdomain: SubdomainStub.new(name: 'metazoa')
    )
    dir = Dir.mktmpdir('scfair-ensembl-gca')
    FileUtils.mkdir_p(File.join(dir, 'parsing'))
    File.write(
      File.join(dir, 'parsing', 'output.json'),
      {
        metadata: [
          { name: '/attrs/ensembl_assembly', categories: { 'GCA_002204515.1' => 1 } },
          { name: '/attrs/ensembl_release', categories: { '62' => 1 } }
        ]
      }.to_json
    )
    project = build_project(
      organism: organism,
      tool_versions: { 'ensembl_genomes' => '62' },
      storage_dir: dir
    )

    result = Scfair::ProjectEnsemblMetadataResolver.call(project, lookup: Object.new)

    assert_equal 'GCA_002204515.1', result[:ensembl_assembly]
    assert_equal 'GCA_002204515.1', result[:ensembl_genome_browser_assembly]
  ensure
    FileUtils.remove_entry(dir) if dir && Dir.exist?(dir)
  end

  test 'returns nil when project has no organism or version' do
    project = ProjectStub.new(organism: nil, version_for_catalog: nil)
    assert_nil Scfair::ProjectEnsemblMetadataResolver.call(project)
  end

  test 'omits assembly when remote lookup is unavailable' do
    organism = OrganismStub.new(
      tax_id: 9606,
      ensembl_subdomain_id: 1,
      ensembl_subdomain: SubdomainStub.new(name: 'vertebrates')
    )
    project = build_project(
      organism: organism,
      tool_versions: { 'ensembl_vertebrate' => '113' }
    )

    lookup = Minitest::Mock.new
    lookup.expect(:remote_available?, false)

    result = Scfair::ProjectEnsemblMetadataResolver.call(project, lookup: lookup)

    assert_equal '113', result[:ensembl_release]
    assert_equal 'Ensembl', result[:ensembl_database]
    refute result.key?(:ensembl_assembly)
    lookup.verify
  end
end
