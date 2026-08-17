# frozen_string_literal: true

require 'test_helper'

class ExternalCatalogLandingEmbeddingTest < ActiveSupport::TestCase
  setup do
    @version = Version.activated.where('id > 3').order(id: :desc).first || Version.order(id: :desc).first
    skip 'No Version available for importer tests' unless @version

    @sc_type = ProjectType.find_by(tag: 'sc') || ProjectType.find_by('name ILIKE ?', '%single%')
    skip 'No single-cell ProjectType' unless @sc_type

    @bulk_type = ProjectType.find_by(tag: 'bulk') || ProjectType.find_by('name ILIKE ?', '%bulk%')
    skip 'No bulk ProjectType' unless @bulk_type

    @user = register_for_test_cleanup(
      User.create!(email: "landing_emb_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )
    @project = create_test_project!(
      name: 'Landing embedding project',
      key: "le#{SecureRandom.hex(3)}",
      user_id: @user.id,
      public: false,
      being_deleted: false,
      project_type_id: @sc_type.id,
      version_id: @version.id
    )
    @loom = 'parsing/output.loom'
    @importer = ExternalCatalog::ProjectImporter.new(
      user: @user,
      version: @version,
      skip_archive: true,
      skip_publish: true,
      dry_run: false
    )
  end

  def create_embedding!(name:, nber_cols: 50, filepath: nil)
    register_for_test_cleanup(
      Annot.create!(
        project_id: @project.id,
        user_id: @user.id,
        filepath: filepath || @loom,
        name: name,
        dim: 1,
        nber_rows: 2,
        nber_cols: nber_cols
      )
    )
  end

  def create_cell_type!(filepath: nil)
    register_for_test_cleanup(
      Annot.create!(
        project_id: @project.id,
        user_id: @user.id,
        filepath: filepath || @loom,
        name: '/col_attrs/cell_type',
        dim: 1,
        nber_rows: 1,
        nber_cols: 50,
        categories_json: { 'T' => 10, 'B' => 20 }.to_json,
        list_cat_json: %w[T B].to_json
      )
    )
  end

  test 'prefers spatial over UMAP and other embeddings' do
    umap = create_embedding!(name: '/col_attrs/X_umap', nber_cols: 40)
    other = create_embedding!(name: '/col_attrs/X_draw_graph_fa', nber_cols: 90)
    spatial = create_embedding!(name: '/col_attrs/spatial', nber_cols: 80)

    chosen = @importer.send(:prefer_embedding_annot, @project)
    assert_equal spatial.id, chosen.id
    assert_not_equal umap.id, chosen.id
    assert_not_equal other.id, chosen.id
  end

  test 'landing checkpoint uses spatial embedding when UMAP is also present' do
    spatial = create_embedding!(name: '/col_attrs/spatial')
    create_embedding!(name: '/col_attrs/X_umap')
    create_cell_type!

    @importer.send(:create_landing_visualization_checkpoint!, @project)

    checkpoint = @project.checkpoints.visualization.find_by(is_landing_page: true)
    assert checkpoint, 'Expected a landing visualization checkpoint'
    assert_equal 'Spatial colored by cell type with labels', checkpoint.title
    assert_equal spatial.id.to_s, checkpoint.state.dig('visualizationEmbedding', 'id')
    assert_equal '/col_attrs/spatial', checkpoint.state.dig('visualizationEmbedding', 'name')
  end

  test 'uses spatial when no UMAP t-SNE or PCA embedding exists' do
    other = create_embedding!(name: '/col_attrs/X_draw_graph_fa', nber_cols: 90)
    spatial = create_embedding!(name: '/col_attrs/spatial', nber_cols: 40)

    chosen = @importer.send(:prefer_embedding_annot, @project)
    assert_equal spatial.id, chosen.id
    assert_not_equal other.id, chosen.id
  end

  test 'uses first remaining embedding when no UMAP t-SNE PCA or spatial exists' do
    later = create_embedding!(name: '/col_attrs/X_diffmap', nber_cols: 30, filepath: 'analysis/output.loom')
    first = create_embedding!(name: '/col_attrs/X_draw_graph_fa', nber_cols: 50)

    chosen = @importer.send(:prefer_embedding_annot, @project)
    assert_equal first.id, chosen.id
    assert_not_equal later.id, chosen.id
  end

  test 'creates landing checkpoint from spatial embedding' do
    spatial = create_embedding!(name: '/col_attrs/spatial')
    create_cell_type!

    @importer.send(:create_landing_visualization_checkpoint!, @project)

    checkpoint = @project.checkpoints.visualization.find_by(is_landing_page: true)
    assert checkpoint, 'Expected a landing visualization checkpoint'
    assert_equal 'Spatial colored by cell type with labels', checkpoint.title
    assert_equal spatial.id.to_s, checkpoint.state.dig('visualizationEmbedding', 'id')
    assert_equal '/col_attrs/spatial', checkpoint.state.dig('visualizationEmbedding', 'name')
  end

  test 'creates landing checkpoint from first embedding when no named method exists' do
    embedding = create_embedding!(name: '/col_attrs/X_draw_graph_fa')
    create_cell_type!

    @importer.send(:create_landing_visualization_checkpoint!, @project)

    checkpoint = @project.checkpoints.visualization.find_by(is_landing_page: true)
    assert checkpoint, 'Expected a landing visualization checkpoint'
    assert_equal 'Scatter plot colored by cell type with labels', checkpoint.title
    assert_equal embedding.id.to_s, checkpoint.state.dig('visualizationEmbedding', 'id')
  end
end
