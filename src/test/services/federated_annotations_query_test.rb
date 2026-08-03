# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class FederatedAnnotationsQueryTest < TestBaseWithoutFixtures
  setup do
    @user = register_for_test_cleanup(User.create!(email: "fed_ann_#{SecureRandom.hex(4)}@example.com", password: 'password123'))
    @project = create_test_project!(name: 'Fed project', key: "fed#{SecureRandom.hex(3)}", user_id: @user.id)
    @pcs = register_for_test_cleanup(ProjectCellSet.create!(key: "pcs#{SecureRandom.hex(4)}"))
    @cell_set = register_for_test_cleanup(CellSet.create!(project_cell_set_id: @pcs.id, key: SecureRandom.hex(8), nber_cells: 10))
    @ott = OntologyTermType.find_by(name: 'cell_type') ||
           register_for_test_cleanup(OntologyTermType.create!(name: 'cell_type', label: 'Cell type'))
    @cla = register_for_test_cleanup(
      Cla.create!(
        project_id: @project.id,
        cell_set_id: @cell_set.id,
        ontology_term_type_id: @ott.id,
        name: 'T cell',
        cat: 'cluster_1',
        nber_agree: 3,
        nber_disagree: 1,
        user_id: @user.id
      )
    )
  end

  test 'returns annotations for readable projects' do
    result = FederatedAnnotationsQuery.call(
      project_ids: [@project.id],
      readable_if: ->(_project) { true },
      current_project: @project
    )
    assert result[:ok]
    assert_equal 1, result[:annotations].size
    assert_equal @cla.id, result[:annotations].first[:id]
    assert result[:annotation_type_options].any?
    assert_equal false, result[:annotations].first[:in_consensus]
  end

  test 'marks annotations present in consensus metadata' do
    data_type_id = DataType.find_by(name: 'DISCRETE')&.id || 3
    label_annot = register_for_test_cleanup(
      @project.annots.create!(
        name: '/col_attrs/_asap_consensus_cell_type',
        label: '_asap_consensus_cell_type',
        filepath: 'main.loom',
        dim: 1,
        data_type_id: data_type_id,
        list_cat_json: ['T cell', 'B cell'].to_json,
        latest_version: true,
        version_nber: 1,
        user_id: @user.id
      )
    )
    ontology_annot = register_for_test_cleanup(
      @project.annots.create!(
        name: '/col_attrs/_asap_consensus_cell_type_ontology_term_id',
        label: '_asap_consensus_cell_type_ontology_term_id',
        filepath: 'main.loom',
        dim: 1,
        data_type_id: data_type_id,
        list_cat_json: ['CL:0000084'].to_json,
        latest_version: true,
        version_nber: 1,
        user_id: @user.id
      )
    )

    result = FederatedAnnotationsQuery.call(
      project_ids: [@project.id],
      readable_if: ->(_project) { true },
      current_project: @project
    )
    assert result[:ok]
    row = result[:annotations].find { |entry| entry[:id] == @cla.id }
    assert row
    assert_equal true, row[:in_consensus]
    assert_equal 'T cell', row[:consensus_label]

    links = result[:consensus_metadata_by_type][@ott.id.to_s]
    assert links
    assert_equal '/col_attrs/_asap_consensus_cell_type', links[:label][:path]
    assert_equal label_annot.id, links[:label][:annot_id]
    assert_equal Rails.application.routes.url_helpers.annot_path(label_annot), links[:label][:url]
    assert_equal '/col_attrs/_asap_consensus_cell_type_ontology_term_id', links[:ontology_term_id][:path]
    assert_equal ontology_annot.id, links[:ontology_term_id][:annot_id]
    assert_equal Rails.application.routes.url_helpers.annot_path(ontology_annot), links[:ontology_term_id][:url]
  end

  test 'rejects when no readable projects' do
    result = FederatedAnnotationsQuery.call(
      project_ids: [@project.id],
      readable_if: ->(_project) { false },
      current_project: @project
    )
    assert_equal false, result[:ok]
  end
end
