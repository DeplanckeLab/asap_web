# frozen_string_literal: true

require 'test_helper'
require 'minitest/mock'

class SpatialUmapEnsureServiceTest < ActiveSupport::TestCase
  setup do
    @version = Version.activated.where('id > 3').order(id: :desc).first || Version.order(id: :desc).first
    skip 'No Version available' unless @version

    @spat = ProjectType.find_by(tag: 'spat')
    skip 'No spat ProjectType' unless @spat

    @user = register_for_test_cleanup(
      User.create!(email: "spat_umap_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )
    @project = create_test_project!(
      name: 'Spatial umap ensure',
      key: "su#{SecureRandom.hex(3)}",
      user_id: @user.id,
      project_type_id: @spat.id,
      version_id: @version.id
    )
    parsing_step = Step.find_by(name: 'parsing', version_id: @version.id) || Step.find_by(name: 'parsing')
    skip 'No parsing step' unless parsing_step
    @parsing_run = Run.create!(
      project_id: @project.id,
      user_id: @user.id,
      step_id: parsing_step.id,
      status_id: 3,
      num: 1,
      command_json: '{}',
      attrs_json: '{}',
      output_json: '{}'
    )
    @matrix = Annot.create!(
      project_id: @project.id,
      user_id: @user.id,
      run_id: @parsing_run.id,
      filepath: 'parsing/output.loom',
      name: '/matrix',
      dim: 3,
      nber_rows: 100,
      nber_cols: 50,
      data_class_ids: DataClass.find_by(name: 'int_matrix')&.id.to_s
    )
  end

  teardown do
    if @project&.id
      Annot.where(project_id: @project.id).delete_all
      Run.where(project_id: @project.id).delete_all
      ProjectStep.where(project_id: @project.id).delete_all
    end
  end

  test 'skips when a UMAP embedding is already present' do
    Annot.create!(
      project_id: @project.id,
      user_id: @user.id,
      filepath: 'parsing/output.loom',
      name: '/col_attrs/X_umap',
      dim: 1,
      nber_rows: 2,
      nber_cols: 50
    )

    result = SpatialUmapEnsureService.call(project: @project, logger: Rails.logger, wait: false)
    assert result.skipped
    assert_equal 'umap_present', result.reason
    assert_nil result.pca_run
  end

  test 'skips non-spatial projects' do
    sc = ProjectType.find_by(tag: 'sc')
    skip 'No sc ProjectType' unless sc
    @project.update!(project_type_id: sc.id)

    result = SpatialUmapEnsureService.call(project: @project.reload, logger: Rails.logger, wait: false)
    assert result.skipped
    assert_equal 'not_spatial', result.reason
  end

  test 'skips PCA when only raw count /matrix is present' do
    result = SpatialUmapEnsureService.call(project: @project, logger: Rails.logger, wait: false)
    assert result.skipped
    assert_equal 'not_normalized', result.reason
    assert_nil result.pca_run
  end

  test 'starts PCA on analysis X when raw counts are in /matrix' do
    num_matrix = DataClass.find_by(name: 'num_matrix')
    skip 'No num_matrix DataClass' unless num_matrix
    x_layer = Annot.create!(
      project_id: @project.id,
      user_id: @user.id,
      run_id: @parsing_run.id,
      filepath: 'parsing/output.loom',
      name: AnndataMappingBuilder::X_LAYER_PATH,
      dim: 3,
      nber_rows: 100,
      nber_cols: 50,
      data_class_ids: num_matrix.id.to_s
    )

    tmp_root = Dir.mktmpdir('spatial-umap-x')
    previous = ENV['USER_DATA_DIR']
    ENV['USER_DATA_DIR'] = tmp_root
    FileUtils.mkdir_p(File.join(tmp_root, @user.id.to_s, @project.key))

    begin
      Basic.stub(:set_run, ->(*) { {} }) do
        Basic.stub(:exec_run, ->(*) { nil }) do
          result = SpatialUmapEnsureService.call(project: @project, logger: Rails.logger, wait: false, user_id: @user.id)
          refute result.skipped, result.error
          assert_equal 'pca_sc', result.pca_run.step.name
          attrs = JSON.parse(result.pca_run.attrs_json)
          assert_equal x_layer.id, attrs.dig('input_matrix', 'annot_id')
        end
      end
    ensure
      ENV['USER_DATA_DIR'] = previous
      FileUtils.rm_rf(tmp_root)
    end
  end

  test 'starts UMAP from a successful PCA run when no UMAP exists' do
    pca_step = Step.find_by(name: 'pca_sc', version_id: @version.id) || Step.find_by(name: 'pca_sc')
    skip 'No pca_sc step' unless pca_step
    pca_run = Run.create!(
      project_id: @project.id,
      user_id: @user.id,
      step_id: pca_step.id,
      status_id: 3,
      num: 1,
      command_json: '{}',
      attrs_json: { 'auto_spatial_from_matrix' => true }.to_json,
      output_json: '{}'
    )
    Annot.create!(
      project_id: @project.id,
      user_id: @user.id,
      run_id: pca_run.id,
      filepath: 'parsing/output.loom',
      name: '/col_attrs/_pca_1_scanpy_50D',
      dim: 1,
      nber_rows: 50,
      nber_cols: 50
    )

    Basic.stub(:set_run, ->(*) { {} }) do
      Basic.stub(:exec_run, ->(*) { nil }) do
        tmp_root = Dir.mktmpdir('spatial-umap-after-pca')
        previous = ENV['USER_DATA_DIR']
        ENV['USER_DATA_DIR'] = tmp_root
        begin
          umap_run = SpatialUmapEnsureService.after_pca_success(Rails.logger, @project, pca_run)
          assert umap_run
          attrs = JSON.parse(umap_run.attrs_json)
          assert_equal true, attrs['auto_spatial_from_matrix']
          assert_equal 2, attrs['n_components']
        ensure
          ENV['USER_DATA_DIR'] = previous
          FileUtils.rm_rf(tmp_root)
        end
      end
    end
  end

  test 'does not start UMAP after PCA when X_umap is already imported' do
    pca_step = Step.find_by(name: 'pca_sc', version_id: @version.id) || Step.find_by(name: 'pca_sc')
    skip 'No pca_sc step' unless pca_step
    pca_run = Run.create!(
      project_id: @project.id,
      user_id: @user.id,
      step_id: pca_step.id,
      status_id: 3,
      num: 1,
      command_json: '{}',
      attrs_json: '{}',
      output_json: '{}'
    )
    Annot.create!(
      project_id: @project.id,
      user_id: @user.id,
      filepath: 'parsing/output.loom',
      name: '/col_attrs/X_umap',
      dim: 1,
      nber_rows: 2,
      nber_cols: 50
    )

    umap_run = SpatialUmapEnsureService.after_pca_success(Rails.logger, @project, pca_run)
    assert_nil umap_run
  end
end
