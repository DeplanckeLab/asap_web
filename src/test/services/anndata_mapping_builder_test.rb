# frozen_string_literal: true

require 'test_helper'

class AnndataMappingBuilderTest < ActiveSupport::TestCase
  setup do
    @user = register_for_test_cleanup(User.create!(email: "amb_#{SecureRandom.hex(4)}@example.com", password: 'password123'))
    @project = create_test_project!(user_id: @user.id, input_filename: 'input_file.h5ad')
    @loom = 'parsing/output.loom'
    @int_matrix = DataClass.find_by!(name: 'int_matrix')
    @num_matrix = DataClass.find_by!(name: 'num_matrix')
    @discrete = DataType.find_by!(name: 'DISCRETE')
  end

  test 'case A raw primary from input_group and layers/X' do
    register_for_test_cleanup(
      Annot.create!(
        project_id: @project.id, user_id: @user.id, filepath: @loom,
        name: '/matrix', dim: 3, nber_rows: 100, nber_cols: 50,
        data_class_ids: @int_matrix.id.to_s
      ),
      Annot.create!(
        project_id: @project.id, user_id: @user.id, filepath: @loom,
        name: '/layers/X', dim: 3, nber_rows: 100, nber_cols: 50,
        data_class_ids: @num_matrix.id.to_s
      ),
      Annot.create!(
        project_id: @project.id, user_id: @user.id, filepath: @loom,
        name: '/col_attrs/CellID', dim: 1, nber_rows: 1, nber_cols: 50
      ),
      Annot.create!(
        project_id: @project.id, user_id: @user.id, filepath: @loom,
        name: '/row_attrs/Accession', dim: 2, nber_rows: 100, nber_cols: 1
      )
    )

    payload = AnndataMappingBuilder.call(
      project: @project,
      loom_filepath: @loom,
      input_group: '/raw/X'
    )

    assert_equal '1.0.0', payload['version']
    assert_equal 'genes_x_cells', payload['orientation']
    assert_equal '/layers/X', payload['x_path']
    assert_equal '/matrix', payload['raw_x_path']
    assert_equal({}, payload['layers'])
    assert_equal '/raw/X', payload['input_group']
    assert_equal 'CellID', payload['obs_index_key']
    assert_equal 'Accession', payload['var_index_key']
  end

  test 'case B normalized primary from input_group /X with raw layer' do
    register_for_test_cleanup(
      Annot.create!(
        project_id: @project.id, user_id: @user.id, filepath: @loom,
        name: '/matrix', dim: 3, nber_rows: 100, nber_cols: 50,
        data_class_ids: @num_matrix.id.to_s
      ),
      Annot.create!(
        project_id: @project.id, user_id: @user.id, filepath: @loom,
        name: '/layers/raw_X', dim: 3, nber_rows: 100, nber_cols: 50,
        data_class_ids: @int_matrix.id.to_s
      )
    )

    payload = AnndataMappingBuilder.call(
      project: @project,
      loom_filepath: @loom,
      input_group: '/X'
    )

    assert_equal '/matrix', payload['x_path']
    assert_equal '/layers/raw_X', payload['raw_x_path']
    assert_equal({}, payload['layers'])
  end

  test 'infers case A from int_matrix plus layers/X without input_group' do
    register_for_test_cleanup(
      Annot.create!(
        project_id: @project.id, user_id: @user.id, filepath: @loom,
        name: '/matrix', dim: 3, nber_rows: 100, nber_cols: 50,
        data_class_ids: @int_matrix.id.to_s
      ),
      Annot.create!(
        project_id: @project.id, user_id: @user.id, filepath: @loom,
        name: '/layers/X', dim: 3, nber_rows: 100, nber_cols: 50,
        data_class_ids: @num_matrix.id.to_s
      )
    )

    payload = AnndataMappingBuilder.call(project: @project, loom_filepath: @loom)
    assert_equal '/layers/X', payload['x_path']
    assert_equal '/matrix', payload['raw_x_path']
  end

  test 'maps multi-dim col_attrs and named embeddings to obsm' do
    register_for_test_cleanup(
      Annot.create!(
        project_id: @project.id, user_id: @user.id, filepath: @loom,
        name: '/matrix', dim: 3, nber_rows: 100, nber_cols: 50
      ),
      Annot.create!(
        project_id: @project.id, user_id: @user.id, filepath: @loom,
        name: '/col_attrs/_umap_1_scanpy_2D', dim: 1, nber_rows: 2, nber_cols: 50
      ),
      Annot.create!(
        project_id: @project.id, user_id: @user.id, filepath: @loom,
        name: '/col_attrs/X_umap', dim: 1, nber_rows: 2, nber_cols: 50
      ),
      Annot.create!(
        project_id: @project.id, user_id: @user.id, filepath: @loom,
        name: '/col_attrs/cell_type', dim: 1, nber_rows: 1, nber_cols: 50,
        data_type_id: @discrete.id,
        list_cat_json: %w[T B myeloid].to_json,
        categories_json: { 'myeloid' => 3, 'B' => 2, 'T' => 1 }.to_json
      )
    )

    payload = AnndataMappingBuilder.call(project: @project, loom_filepath: @loom)
    assert_equal '/col_attrs/_umap_1_scanpy_2D', payload['obsm']['_umap_1_scanpy_2D']
    assert_equal '/col_attrs/X_umap', payload['obsm']['X_umap']
    refute payload['obsm'].key?('cell_type')
    assert_equal %w[T B myeloid], payload['categoricals']['cell_type']['categories']
    assert_includes payload['uns_json_keys'], 'analysis_pipeline'
  end

  test 'preserves existing x_path when completing without input_group' do
    register_for_test_cleanup(
      Annot.create!(
        project_id: @project.id, user_id: @user.id, filepath: @loom,
        name: '/matrix', dim: 3, nber_rows: 100, nber_cols: 50,
        data_class_ids: @int_matrix.id.to_s
      ),
      Annot.create!(
        project_id: @project.id, user_id: @user.id, filepath: @loom,
        name: '/layers/X', dim: 3, nber_rows: 100, nber_cols: 50
      ),
      Annot.create!(
        project_id: @project.id, user_id: @user.id, filepath: @loom,
        name: '/col_attrs/spatial', dim: 1, nber_rows: 2, nber_cols: 50
      )
    )

    payload = AnndataMappingBuilder.call(
      project: @project,
      loom_filepath: @loom,
      existing: {
        'x_path' => '/matrix',
        'raw_x_path' => '/layers/raw_X',
        'input_group' => '/X',
        'layers' => {}
      }
    )

    assert_equal '/matrix', payload['x_path']
    assert_equal '/layers/raw_X', payload['raw_x_path']
    assert_equal '/X', payload['input_group']
    assert_equal '/col_attrs/spatial', payload['obsm']['spatial']
  end
end
