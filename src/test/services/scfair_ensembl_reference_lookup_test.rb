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
end
