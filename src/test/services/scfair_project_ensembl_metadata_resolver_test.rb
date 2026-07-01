# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class ScfairProjectEnsemblMetadataResolverTest < TestBaseWithoutFixtures
  VersionStub = Struct.new(:env_data, keyword_init: true)
  OrganismStub = Struct.new(:tax_id, :ensembl_subdomain_id, :ensembl_subdomain, keyword_init: true)
  SubdomainStub = Struct.new(:name, keyword_init: true)
  ProjectStub = Struct.new(:organism, :version_for_catalog, keyword_init: true)

  def build_project(organism:, tool_versions:, remote_db: 'asap_data_v8')
    version = VersionStub.new(
      env_data: {
        'tool_versions' => tool_versions,
        'asap_data_db_name' => remote_db
      }
    )
    ProjectStub.new(organism: organism, version_for_catalog: version)
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

    result = Scfair::ProjectEnsemblMetadataResolver.call(project, lookup: lookup)

    assert_equal '113', result[:ensembl_release]
    assert_equal 'Ensembl', result[:ensembl_database]
    assert_equal 'GRCh38.p14', result[:ensembl_assembly]
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

    result = Scfair::ProjectEnsemblMetadataResolver.call(project, lookup: lookup)

    assert_equal '60', result[:ensembl_release]
    assert_equal 'EnsemblMetazoa', result[:ensembl_database]
    assert_equal 'BDGP6.46', result[:ensembl_assembly]
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
    lookup.verify
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
