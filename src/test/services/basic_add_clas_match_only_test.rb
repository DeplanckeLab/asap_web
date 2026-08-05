# frozen_string_literal: true

require 'minitest/mock'
require_relative 'test_base_without_fixtures'

class BasicAddClasMatchOnlyTest < TestBaseWithoutFixtures
  setup do
    suffix = SecureRandom.hex(4)
    ensure_cla_source!(Basic::ASAP_AUTO_CLA_SOURCE_ID, "asap_auto_#{suffix}")

    @user = register_for_test_cleanup(
      User.create!(email: "addclas_#{suffix}@example.com", password: 'password123')
    )
    @project = create_test_project!(
      name: "Add clas #{suffix}",
      key: "ac#{suffix[0, 6]}",
      user_id: @user.id
    )

    @co = register_for_test_cleanup(
      CellOntology.create!(name: "AddClas CO #{suffix}", tag: "ACC#{suffix}", obsolete: false)
    )
    @cot = register_for_test_cleanup(
      CellOntologyTerm.create!(
        cell_ontology_id: @co.id,
        identifier: "ACC#{suffix}:1",
        name: "Matched label #{suffix}",
        original: true,
        obsolete: false
      )
    )
    @ott = register_for_test_cleanup(
      OntologyTermType.create!(
        name: "addclas_type_#{suffix}",
        label: 'Add clas type',
        cell_ontology_ids: @co.id.to_s,
        term_path: '/col_attrs/cell_type_ontology_term_id',
        field_group_id: "addclas_#{suffix}"
      )
    )

    @matched_label = @cot.name
    @unmatched_label = "no_match_#{suffix}"

    data_type_id = DataType.find_by(name: 'DISCRETE')&.id || 3
    @annot = register_for_test_cleanup(
      @project.annots.create!(
        name: "/col_attrs/test_meta_#{suffix}",
        filepath: 'main.loom',
        dim: 1,
        data_type_id: data_type_id,
        list_cat_json: [@matched_label, @unmatched_label].to_json,
        latest_version: true,
        version_nber: 1,
        user_id: @user.id
      )
    )

    @pcs = register_for_test_cleanup(ProjectCellSet.create!(key: "pcs#{suffix}"))
    @cell_set_0 = register_for_test_cleanup(
      CellSet.create!(project_cell_set_id: @pcs.id, key: SecureRandom.hex(8), nber_cells: 1)
    )
    @cell_set_1 = register_for_test_cleanup(
      CellSet.create!(project_cell_set_id: @pcs.id, key: SecureRandom.hex(8), nber_cells: 1)
    )
  end

  test 'add_clas creates only matched ontology slots and sets type' do
    h_cell_sets = { 0 => @cell_set_0, 1 => @cell_set_1 }

    Scfair::OntologySemanticRules.stub(:rules_for, ->(_field) { nil }) do
      Basic.stub(:h_cell_ontology_terms_by_cat_label, lambda { |labels, _tax = nil|
        labels.index_with { |label| label == @matched_label ? @cot : nil }
      }) do
        Basic.add_clas(@project, @annot, h_cell_sets)
      end
    end

    asap_clas = Cla.where(annot_id: @annot.id, cla_source_id: Basic::ASAP_AUTO_CLA_SOURCE_ID).order(:cat_idx).to_a
    assert_equal 1, asap_clas.size
    cla = asap_clas.first
    assert_equal 0, cla.cat_idx
    assert_equal '', cla.name.to_s
    assert_equal @cot.id.to_s, cla.cell_ontology_term_ids.to_s
    assert_equal @ott.id, cla.ontology_term_type_id
    assert_equal @matched_label, cla.cat

    @annot.reload
    info = JSON.parse(@annot.cat_info_json)
    assert_equal [1, 0], info['nber_clas']
    assert_equal [cla.id, ''], info['selected_cla_ids']
  end

  test 'add_clas leaves selected empty when no category matches ontology' do
    @annot.update!(list_cat_json: [@unmatched_label].to_json)
    h_cell_sets = { 0 => @cell_set_0 }

    Basic.stub(:h_cell_ontology_terms_by_cat_label, lambda { |_labels, _tax = nil|
      { @unmatched_label => nil }
    }) do
      Basic.add_clas(@project, @annot, h_cell_sets)
    end

    assert_equal 0, Cla.where(annot_id: @annot.id, cla_source_id: Basic::ASAP_AUTO_CLA_SOURCE_ID).count
    @annot.reload
    info = JSON.parse(@annot.cat_info_json)
    assert_equal [0], info['nber_clas']
    assert_equal [''], info['selected_cla_ids']
  end

  private

  def ensure_cla_source!(id, name)
    source = ClaSource.find_by(id: id)
    return source if source

    register_for_test_cleanup(ClaSource.create!(id: id, name: name, label: name))
  end
end
