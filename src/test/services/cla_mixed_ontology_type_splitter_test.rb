# frozen_string_literal: true

require 'minitest/mock'
require_relative 'test_base_without_fixtures'

class ClaMixedOntologyTypeSplitterTest < TestBaseWithoutFixtures
  setup do
    suffix = SecureRandom.hex(4)
    ensure_cla_source!(Basic::MANUAL_CLA_SOURCE_ID, "manual_#{suffix}")

    @user = register_for_test_cleanup(
      User.create!(email: "split_#{suffix}@example.com", password: 'password123')
    )
    @project = create_test_project!(
      name: "Split #{suffix}",
      key: "sp#{suffix[0, 6]}",
      user_id: @user.id
    )

    @co_cl = register_for_test_cleanup(
      CellOntology.create!(name: "Split CL #{suffix}", tag: "SCL#{suffix}", obsolete: false)
    )
    @co_ub = register_for_test_cleanup(
      CellOntology.create!(name: "Split UB #{suffix}", tag: "SUB#{suffix}", obsolete: false)
    )

    @cot_cl = register_for_test_cleanup(
      CellOntologyTerm.create!(
        cell_ontology_id: @co_cl.id,
        identifier: "SCL#{suffix}:1",
        name: "T cell #{suffix}",
        original: true,
        obsolete: false
      )
    )
    @root_tissue = register_for_test_cleanup(
      CellOntologyTerm.create!(
        cell_ontology_id: @co_ub.id,
        identifier: "SUB#{suffix}:1062",
        name: "anatomical root #{suffix}",
        original: true,
        obsolete: false,
        lineage: ''
      )
    )
    @cot_tissue = register_for_test_cleanup(
      CellOntologyTerm.create!(
        cell_ontology_id: @co_ub.id,
        identifier: "SUB#{suffix}:2000",
        name: "heart #{suffix}",
        original: true,
        obsolete: false,
        lineage: @root_tissue.id.to_s
      )
    )

    @ott_cell_type = register_for_test_cleanup(
      OntologyTermType.create!(
        name: "split_cell_type_#{suffix}",
        label: 'Cell type',
        cell_ontology_ids: @co_cl.id.to_s,
        term_path: '/col_attrs/cell_type_ontology_term_id',
        field_group_id: "split_ct_#{suffix}"
      )
    )
    @ott_tissue = register_for_test_cleanup(
      OntologyTermType.create!(
        name: "split_tissue_#{suffix}",
        label: 'Tissue',
        cell_ontology_ids: @co_ub.id.to_s,
        term_path: '/col_attrs/tissue_ontology_term_id',
        field_group_id: "split_ti_#{suffix}"
      )
    )
    # Second overlapping OTT so semantic roots are required for UBERON disambiguation
    register_for_test_cleanup(
      OntologyTermType.create!(
        name: "split_stage_#{suffix}",
        label: 'Stage',
        cell_ontology_ids: @co_ub.id.to_s,
        term_path: '/col_attrs/development_stage_ontology_term_id',
        field_group_id: "split_st_#{suffix}"
      )
    )

    @pcs = register_for_test_cleanup(ProjectCellSet.create!(key: "pcs#{suffix}"))
    @cell_set = register_for_test_cleanup(
      CellSet.create!(project_cell_set_id: @pcs.id, key: SecureRandom.hex(8), nber_cells: 3)
    )

    mixed_ids = [@cot_cl.id, @cot_tissue.id].join(',')
    @cla = register_for_test_cleanup(
      Cla.create!(
        project_id: @project.id,
        cell_set_id: @cell_set.id,
        cla_source_id: Basic::MANUAL_CLA_SOURCE_ID,
        user_id: @user.id,
        cat: 'cluster_1',
        cat_idx: 0,
        name: '',
        cell_ontology_term_ids: mixed_ids,
        sorted_cell_ontology_term_ids: mixed_ids,
        nber_agree: 2,
        nber_disagree: 0
      )
    )

    @rules = {
      'cell_type_ontology_term_id' => nil,
      'tissue_ontology_term_id' => { any_roots: [@root_tissue.identifier] },
      'development_stage_ontology_term_id' => { any_roots: ['UBERON:0000105'] }
    }
  end

  test 'dry_run plans split without writing' do
    Scfair::OntologySemanticRules.stub(:rules_for, ->(field) { @rules[field.to_s] }) do
      result = ClaMixedOntologyTypeSplitter.apply!(@cla, dry_run: true)
      plan = result[:plan]
      assert_equal :split, plan.action
      assert_equal 1, plan.creates.size
      assert_empty result[:created]
      @cla.reload
      assert_includes @cla.cell_ontology_term_ids, @cot_cl.id.to_s
      assert_includes @cla.cell_ontology_term_ids, @cot_tissue.id.to_s
    end
  end

  test 'apply splits mixed terms into typed clas' do
    Scfair::OntologySemanticRules.stub(:rules_for, ->(field) { @rules[field.to_s] }) do
      result = ClaMixedOntologyTypeSplitter.apply!(@cla, dry_run: false)
      plan = result[:plan]
      assert_equal :split, plan.action
      assert_equal 1, result[:created].size

      @cla.reload
      created = result[:created].first
      register_for_test_cleanup(created)

      assert_equal plan.primary_ott_id, @cla.ontology_term_type_id
      assert_equal format_ids(plan.primary_cot_ids), @cla.cell_ontology_term_ids.to_s
      assert_equal created.clone_id, @cla.id
      assert_equal plan.creates.first.ontology_term_type_id, created.ontology_term_type_id
      assert_equal format_ids(plan.creates.first.cot_ids), created.cell_ontology_term_ids.to_s
      assert_equal 0, created.nber_agree
    end
  end

  test 'skips when all terms share one annotation type' do
    @cla.update!(cell_ontology_term_ids: @cot_cl.id.to_s)
    Scfair::OntologySemanticRules.stub(:rules_for, ->(field) { @rules[field.to_s] }) do
      plan = ClaMixedOntologyTypeSplitter.plan_for(@cla)
      assert_equal :skip, plan.action
    end
  end

  private

  def format_ids(ids)
    Array(ids).map(&:to_i).join(',')
  end

  def ensure_cla_source!(id, name)
    source = ClaSource.find_by(id: id)
    return source if source

    register_for_test_cleanup(ClaSource.new(id: id, name: name, label: name).tap { |s|
      s.save!(validate: false)
    })
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    ClaSource.find(id)
  end
end
