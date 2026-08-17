# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class ScfairAssayProjectTypeHelperTest < TestBaseWithoutFixtures
  test 'visium assay term maps to spat' do
    field_values = { 'obs/assay_ontology_term_id' => ['EFO:0022857'] }

    assert_equal 'spat', Scfair::AssayProjectTypeHelper.tag_for(field_values: field_values, format: 'h5ad')
  end

  test 'slide-seq assay term maps to spat' do
    field_values = { '/col_attrs/assay_ontology_term_id' => ['EFO:0030062'] }

    assert_equal 'spat', Scfair::AssayProjectTypeHelper.tag_for(field_values: field_values, format: 'loom')
  end

  test 'visium assay label maps to spat when ontology id is absent' do
    field_values = { 'obs/assay' => ['Visium Spatial Gene Expression V1'] }

    assert_equal 'spat', Scfair::AssayProjectTypeHelper.tag_for(field_values: field_values, format: 'h5ad')
  end

  test '10x multiome assay maps to multi before atac' do
    field_values = { 'obs/assay_ontology_term_id' => ['EFO:0030059'] }

    assert_equal 'multi', Scfair::AssayProjectTypeHelper.tag_for(field_values: field_values, format: 'h5ad')
  end

  test 'scATAC-seq root assay maps to atac' do
    field_values = { 'obs/assay_ontology_term_id' => ['EFO:0010891'] }

    assert_equal 'atac', Scfair::AssayProjectTypeHelper.tag_for(field_values: field_values, format: 'h5ad')
  end

  test 'ATAC descendant maps to atac via ontology lineage' do
    resolver = Object.new
    def resolver.descendant_of?(term, root)
      term == 'EFO:NEW_ATAC' && root == 'EFO:0010891'
    end
    field_values = { 'obs/assay_ontology_term_id' => ['EFO:NEW_ATAC'] }

    assert_equal 'atac', Scfair::AssayProjectTypeHelper.tag_for(
      field_values: field_values,
      format: 'h5ad',
      resolver: resolver
    )
  end

  test 'ATAC assay label maps to atac when ontology id is absent' do
    field_values = { '/col_attrs/assay' => ['scATAC-seq'] }

    assert_equal 'atac', Scfair::AssayProjectTypeHelper.tag_for(field_values: field_values, format: 'loom')
  end

  test 'spatial assay wins over multiome when both are present' do
    field_values = {
      'obs/assay_ontology_term_id' => ['EFO:0022857', 'EFO:0030059']
    }

    assert_equal 'spat', Scfair::AssayProjectTypeHelper.tag_for(field_values: field_values, format: 'h5ad')
  end

  test 'standard scRNA-seq assay does not map to spat atac or multi' do
    field_values = { 'obs/assay_ontology_term_id' => ['EFO:0009899'] }

    assert_nil Scfair::AssayProjectTypeHelper.tag_for(field_values: field_values, format: 'h5ad')
  end
end
