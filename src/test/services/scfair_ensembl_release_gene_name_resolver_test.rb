# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class ScfairEnsemblReleaseGeneNameResolverTest < TestBaseWithoutFixtures
  test 'resolves display gene names for ensembl release from local dumps' do
    resolver = Scfair::EnsemblReleaseGeneNameResolver.new
    skip 'Local Ensembl data unavailable' unless resolver.available?

    resolver.preload!(
      db_type: :vertebrates,
      ensembl_db_name: 'homo_sapiens',
      release: 114,
      ensembl_ids: %w[ENSG00000237491 ENSG00000241860 ENSG00000272512]
    )

    assert_equal 'LINC01409', resolver.gene_name_for(
      'ENSG00000237491',
      db_type: :vertebrates,
      ensembl_db_name: 'homo_sapiens',
      release: 114
    )
    assert_equal 'ENSG00000241860', resolver.gene_name_for(
      'ENSG00000241860',
      db_type: :vertebrates,
      ensembl_db_name: 'homo_sapiens',
      release: 114
    )
    assert_equal 'ENSG00000272512', resolver.gene_name_for(
      'ENSG00000272512',
      db_type: :vertebrates,
      ensembl_db_name: 'homo_sapiens',
      release: 114
    )
  end
end
