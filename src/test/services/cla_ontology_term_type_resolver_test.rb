# frozen_string_literal: true

require 'minitest/mock'
require_relative 'test_base_without_fixtures'

class ClaOntologyTermTypeResolverTest < TestBaseWithoutFixtures
  setup do
    suffix = SecureRandom.hex(4)
    @co_cl = register_for_test_cleanup(
      CellOntology.create!(name: "Test CL #{suffix}", tag: "TCL#{suffix}", obsolete: false)
    )
    @co_uberon = register_for_test_cleanup(
      CellOntology.create!(name: "Test UBERON #{suffix}", tag: "TUB#{suffix}", obsolete: false)
    )

    @cot_cl = register_for_test_cleanup(
      CellOntologyTerm.create!(
        cell_ontology_id: @co_cl.id,
        identifier: "TCL#{suffix}:0001",
        name: "Test cell type #{suffix}",
        original: true,
        obsolete: false,
        lineage: ''
      )
    )

    @root_tissue = register_for_test_cleanup(
      CellOntologyTerm.create!(
        cell_ontology_id: @co_uberon.id,
        identifier: "TUB#{suffix}:1062",
        name: "anatomical entity root #{suffix}",
        original: true,
        obsolete: false,
        lineage: ''
      )
    )
    @root_stage = register_for_test_cleanup(
      CellOntologyTerm.create!(
        cell_ontology_id: @co_uberon.id,
        identifier: "TUB#{suffix}:0105",
        name: "life cycle stage root #{suffix}",
        original: true,
        obsolete: false,
        lineage: ''
      )
    )
    @cot_tissue = register_for_test_cleanup(
      CellOntologyTerm.create!(
        cell_ontology_id: @co_uberon.id,
        identifier: "TUB#{suffix}:2000",
        name: "heart #{suffix}",
        original: true,
        obsolete: false,
        lineage: @root_tissue.id.to_s
      )
    )
    @cot_stage = register_for_test_cleanup(
      CellOntologyTerm.create!(
        cell_ontology_id: @co_uberon.id,
        identifier: "TUB#{suffix}:3000",
        name: "embryo stage #{suffix}",
        original: true,
        obsolete: false,
        lineage: @root_stage.id.to_s
      )
    )

    @ott_cell_type = register_for_test_cleanup(
      OntologyTermType.create!(
        name: "cell_type_#{suffix}",
        label: 'Cell type',
        cell_ontology_ids: @co_cl.id.to_s,
        term_path: '/col_attrs/cell_type_ontology_term_id',
        field_group_id: "cell_type_#{suffix}"
      )
    )
    @ott_tissue = register_for_test_cleanup(
      OntologyTermType.create!(
        name: "tissue_#{suffix}",
        label: 'Tissue',
        cell_ontology_ids: @co_uberon.id.to_s,
        term_path: '/col_attrs/tissue_ontology_term_id',
        field_group_id: "tissue_#{suffix}"
      )
    )
    @ott_stage = register_for_test_cleanup(
      OntologyTermType.create!(
        name: "developmental_stage_#{suffix}",
        label: 'Developmental stage',
        cell_ontology_ids: @co_uberon.id.to_s,
        term_path: '/col_attrs/development_stage_ontology_term_id',
        field_group_id: "development_stage_#{suffix}"
      )
    )

    @tissue_root_id = @root_tissue.identifier
    @stage_root_id = @root_stage.identifier
  end

  test 'returns empty for blank cot ids' do
    result = ClaOntologyTermTypeResolver.call([])
    assert_equal :empty, result.status
    assert_nil result.ontology_term_type_id
  end

  test 'resolves uniquely when one ontology term type covers the ontology' do
    Scfair::OntologySemanticRules.stub(:rules_for, ->(_field) { nil }) do
      result = ClaOntologyTermTypeResolver.call(@cot_cl.id)
      assert_equal :unique, result.status
      assert_equal @ott_cell_type.id, result.ontology_term_type_id
    end
  end

  test 'disambiguates UBERON via semantic roots' do
    rules_by_field = {
      'tissue_ontology_term_id' => { any_roots: [@tissue_root_id] },
      'development_stage_ontology_term_id' => { any_roots: [@stage_root_id] },
      'cell_type_ontology_term_id' => { any_roots: ['CL:0000000'] }
    }

    Scfair::OntologySemanticRules.stub(:rules_for, ->(field) { rules_by_field[field.to_s] }) do
      tissue_result = ClaOntologyTermTypeResolver.call(@cot_tissue.id)
      assert_equal :unique, tissue_result.status, tissue_result.inspect
      assert_equal @ott_tissue.id, tissue_result.ontology_term_type_id

      stage_result = ClaOntologyTermTypeResolver.call(@cot_stage.id)
      assert_equal :unique, stage_result.status, stage_result.inspect
      assert_equal @ott_stage.id, stage_result.ontology_term_type_id
    end
  end

  test 'leaves nil when semantic roots leave multiple candidates' do
    rules_by_field = {
      'tissue_ontology_term_id' => { any_roots: [@tissue_root_id, @stage_root_id] },
      'development_stage_ontology_term_id' => { any_roots: [@tissue_root_id, @stage_root_id] }
    }

    Scfair::OntologySemanticRules.stub(:rules_for, ->(field) { rules_by_field[field.to_s] }) do
      result = ClaOntologyTermTypeResolver.call(@cot_tissue.id)
      assert_equal :ambiguous, result.status
      assert_nil result.ontology_term_type_id
      assert_includes result.candidate_ids, @ott_tissue.id
      assert_includes result.candidate_ids, @ott_stage.id
    end
  end

  test 'Basic.ontology_term_type_id_for_cot_ids delegates to resolver' do
    Scfair::OntologySemanticRules.stub(:rules_for, ->(_field) { nil }) do
      assert_equal @ott_cell_type.id, Basic.ontology_term_type_id_for_cot_ids(@cot_cl.id)
    end
  end

  test 'group_cot_ids_by_type splits mixed annotation types' do
    rules_by_field = {
      'tissue_ontology_term_id' => { any_roots: [@tissue_root_id] },
      'development_stage_ontology_term_id' => { any_roots: [@stage_root_id] },
      'cell_type_ontology_term_id' => nil
    }

    Scfair::OntologySemanticRules.stub(:rules_for, ->(field) { rules_by_field[field.to_s] }) do
      groups = ClaOntologyTermTypeResolver.group_cot_ids_by_type(
        [@cot_cl.id, @cot_tissue.id, @cot_stage.id]
      )
      assert_equal [@cot_cl.id], groups[@ott_cell_type.id]
      assert_equal [@cot_tissue.id], groups[@ott_tissue.id]
      assert_equal [@cot_stage.id], groups[@ott_stage.id]
    end
  end
end
