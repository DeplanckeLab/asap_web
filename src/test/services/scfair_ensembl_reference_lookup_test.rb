# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class ScfairEnsemblReferenceLookupTest < TestBaseWithoutFixtures
  test 'gene_for_reference_and_index resolves gene_name from ASAP genes by ensembl id' do
    lookup = Scfair::EnsemblReferenceLookup.new
    skip 'ASAP reference genes unavailable' unless lookup.remote_available?

    organism = lookup.remote_organism_for_tax_id(9606)
    skip 'Homo sapiens reference organism unavailable' unless organism

    gene = lookup.gene_for_reference_and_index('NCBITaxon:9606', 'ENSG00000141510')
    skip 'TP53 reference gene unavailable' unless gene

    expected = lookup.expected_feature_name(
      feature_reference: 'NCBITaxon:9606',
      index_id: 'ENSG00000141510',
      biotype: 'gene'
    )

    assert_equal 'TP53', gene.name
    assert_equal 'TP53', expected
  end

  test 'expected_feature_name uses ensembl release gene names when available' do
    lookup = Scfair::EnsemblReferenceLookup.new
    skip 'ASAP reference genes unavailable' unless lookup.remote_available?

    resolver = Scfair::EnsemblReleaseGeneNameResolver.new
    skip 'Local Ensembl data unavailable' unless resolver.available?

    lookup = Scfair::EnsemblReferenceLookup.new(release_gene_names: resolver)
    lookup.preload_release_gene_names(
      feature_reference: 'NCBITaxon:9606',
      release: 114,
      ensembl_ids: %w[ENSG00000237491 ENSG00000241860]
    )

    assert_equal 'LINC01409', lookup.expected_feature_name(
      feature_reference: 'NCBITaxon:9606',
      index_id: 'ENSG00000237491',
      biotype: 'gene',
      release: 114
    )
    assert_equal 'ENSG00000241860', lookup.expected_feature_name(
      feature_reference: 'NCBITaxon:9606',
      index_id: 'ENSG00000241860',
      biotype: 'gene',
      release: 114
    )
  end

  test 'resolve_release_for_gene_reference prefers declared release' do
    lookup = Scfair::EnsemblReferenceLookup.new
    release = lookup.resolve_release_for_gene_reference(
      feature_reference: 'NCBITaxon:9606',
      ensembl_release: '114',
      ensembl_assembly: 'GRCh38.p14'
    )

    assert_equal 114, release
  end

  test 'resolve_release_for_gene_reference uses assembly latest release when release missing' do
    lookup = Scfair::EnsemblReferenceLookup.new
    skip 'ASAP assemblies unavailable' unless lookup.remote_available?

    release = lookup.resolve_release_for_gene_reference(
      feature_reference: 'NCBITaxon:9606',
      ensembl_assembly: 'GRCh38.p13'
    )

    assert_equal 109, release
  end

  test 'resolve_release_for_gene_reference uses latest local release when release and assembly missing' do
    lookup = Scfair::EnsemblReferenceLookup.new
    skip 'Local Ensembl data unavailable' unless Scfair::EnsemblReleaseGeneNameResolver.new.available?

    release = lookup.resolve_release_for_gene_reference(
      feature_reference: 'NCBITaxon:9606'
    )

    assert_equal 115, release
    assert_equal 'GRCh38.p14', lookup.assembly_for_gene_reference(feature_reference: 'NCBITaxon:9606')
  end

  test 'remote_organism_for_tax_id prefers reference ensembl_db_name over strain databases' do
    lookup = Scfair::EnsemblReferenceLookup.new(remote_db: 'asap_data_v8')
    skip 'ASAP reference genes unavailable' unless lookup.remote_available?

    organism = lookup.remote_organism_for_tax_id(10090)
    skip 'Mus musculus reference organism unavailable' unless organism

    assert_equal 'mus_musculus', organism.ensembl_db_name
    assert_equal 2, organism.id
  end

  test 'gene_status_at_release finds mouse genes in asap_data_v8 at release 113' do
    lookup = Scfair::EnsemblReferenceLookup.new(remote_db: 'asap_data_v8')
    skip 'ASAP reference genes unavailable' unless lookup.remote_available?

    organism = lookup.remote_organism_for_tax_id(10090)
    skip 'Mus musculus reference organism unavailable' unless organism

    status = lookup.gene_status_at_release(
      organism_id: organism.id,
      release: 113,
      ensembl_id: 'ENSMUSG00000109644'
    )
    assert_equal :ok, status
  end

  test 'assemblies_for_tax_id reads from latest asap_data DB even when lookup uses older remote_db' do
    lookup = Scfair::EnsemblReferenceLookup.new(remote_db: 'asap_data_v4')
    skip 'ASAP assemblies unavailable' unless lookup.assemblies_remote_available?

    latest_db = Asap2RemoteRecord.latest_remote_db
    skip 'Latest assemblies DB unavailable' unless latest_db

    assemblies = lookup.assemblies_for_tax_id(7159)
    skip 'Aedes assemblies unavailable in latest DB' if assemblies.empty?

    assert_equal latest_db, lookup.assemblies_remote_db
    assert assemblies.any? { |row| row.name == 'AaegL5' }
  end

  test 'insdc_accession_for_assembly maps AaegL5 to GCA accession for Aedes aegypti' do
    lookup = Scfair::EnsemblReferenceLookup.new(remote_db: 'asap_data_v8')
    skip 'ASAP assemblies unavailable' unless lookup.remote_available?

    accession = lookup.insdc_accession_for_assembly(7159, 'AaegL5', release: 62)
    skip 'AaegL5 assembly or INSDC accession not populated yet' if accession.blank?

    assert_equal 'GCA_002204515.1', accession
  end

  test 'gene_statuses_at_release batches mouse gene lookups' do
    lookup = Scfair::EnsemblReferenceLookup.new(remote_db: 'asap_data_v8')
    skip 'ASAP reference genes unavailable' unless lookup.remote_available?

    organism = lookup.remote_organism_for_tax_id(10090)
    skip 'Mus musculus reference organism unavailable' unless organism

    ids = %w[ENSMUSG00000109644 ENSMUSG00000108652 ENSMUSG00000086714 MISSINGGENE0001]
    statuses = lookup.gene_statuses_at_release(
      organism_id: organism.id,
      release: 113,
      ensembl_ids: ids
    )

    assert_equal :ok, statuses['ENSMUSG00000109644']
    assert_equal :ok, statuses['ENSMUSG00000108652']
    assert_equal :ok, statuses['ENSMUSG00000086714']
    assert_equal :not_found, statuses['MISSINGGENE0001']
  end
end
