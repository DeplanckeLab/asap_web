# frozen_string_literal: true

require 'test_helper'
require 'minitest/mock'

class BasicH5adExportStatusTest < ActiveSupport::TestCase
  setup do
    @tmp_root = Dir.mktmpdir('h5ad_export_status')
    @prev_user_data_dir = ENV['USER_DATA_DIR']
    ENV['USER_DATA_DIR'] = @tmp_root

    @user = register_for_test_cleanup(User.create!(email: "h5ad_#{SecureRandom.hex(4)}@example.com", password: 'password123'))
    @project = create_test_project!(user_id: @user.id, input_filename: 'input_file.loom')
    @project_dir = Pathname.new(@tmp_root) + @user.id.to_s + @project.key
    FileUtils.mkdir_p(@project_dir + 'parsing')
    @loom_rel = 'parsing/output.loom'
    @loom_abs = @project_dir + @loom_rel
    @h5ad_abs = @project_dir + 'parsing/output.h5ad'
    File.write(@loom_abs, 'loom-bytes')
  end

  teardown do
    ENV['USER_DATA_DIR'] = @prev_user_data_dir
    FileUtils.rm_rf(@tmp_root) if @tmp_root && File.exist?(@tmp_root)
  end

  test 'h5ad_rel_path_for_loom swaps extension' do
    assert_equal 'parsing/output.h5ad', Basic.h5ad_rel_path_for_loom('parsing/output.loom')
  end

  test 'normalize_project_loom_rel rejects path escape and non-loom' do
    assert_raises(ArgumentError) { Basic.normalize_project_loom_rel('../x.loom') }
    assert_raises(ArgumentError) { Basic.normalize_project_loom_rel('parsing/output.h5ad') }
    assert_equal 'parsing/output.loom', Basic.normalize_project_loom_rel('/parsing/output.loom')
  end

  test 'h5ad_export_status missing when no file and no run' do
    assert_equal 'missing', Basic.h5ad_export_status(@project, @loom_rel, run: nil)
  end

  test 'h5ad_export_status ready when h5ad exists and is not older than loom' do
    File.write(@h5ad_abs, 'h5ad-bytes')
    FileUtils.touch(@h5ad_abs, mtime: Time.now + 2)
    assert_equal 'ready', Basic.h5ad_export_status(@project, @loom_rel, run: nil)
  end

  test 'h5ad_export_status stale when loom newer than h5ad' do
    File.write(@h5ad_abs, 'h5ad-bytes')
    sleep 0.05
    FileUtils.touch(@loom_abs, mtime: Time.now + 5)
    assert_equal 'stale', Basic.h5ad_export_status(@project, @loom_rel, run: nil)
  end

  test 'h5ad_export_status pending and running from run status' do
    pending_run = Struct.new(:status_id).new(1)
    running_run = Struct.new(:status_id).new(2)
    failed_run = Struct.new(:status_id).new(4)
    assert_equal 'pending', Basic.h5ad_export_status(@project, @loom_rel, run: pending_run)
    assert_equal 'running', Basic.h5ad_export_status(@project, @loom_rel, run: running_run)
    assert_equal 'failed', Basic.h5ad_export_status(@project, @loom_rel, run: failed_run)
  end

  test 'get_file no longer contains sync sceasy convert block' do
    source = File.read(Rails.root.join('app/controllers/projects_controller.rb'))
    refute_match(/CREATE H5AD file/, source)
    refute_match(/sceasy::convertFormat/, source)
  end

  test 'get_latest_asap_docker picks highest major tag' do
    latest = Basic.get_latest_asap_docker
    assert latest, 'expected an asap_run DockerImage row'
    assert_equal ENV.fetch('ASAP_DOCKER_NAME'), latest.name
    majors = DockerImage.where(name: latest.name).map { |di| Basic.asap_docker_major_version(di) }
    assert_equal majors.max, Basic.asap_docker_major_version(latest)
  end

  test 'h_env_with_asap_run_docker overrides name and tag without mutating input' do
    latest = Basic.get_latest_asap_docker
    assert latest
    original = {
      'docker_images' => {
        'asap_run' => { 'name' => 'fabdavid/asap_run', 'tag' => 'v4', 'call' => 'docker run #image_name -c' }
      }
    }
    patched = Basic.h_env_with_asap_run_docker(original, latest)
    assert_equal 'v4', original.dig('docker_images', 'asap_run', 'tag')
    assert_equal latest.tag, patched.dig('docker_images', 'asap_run', 'tag')
    assert_equal latest.name, patched.dig('docker_images', 'asap_run', 'name')
    assert_equal 'docker run #image_name -c', patched.dig('docker_images', 'asap_run', 'call')
  end

  test 'export_h5ad_step_and_std_method resolves from latest docker image' do
    image, step, std_method = Basic.export_h5ad_step_and_std_method
    skip 'export_h5ad not upserted in this DB' unless step && std_method
    assert_equal image.id, step.docker_image_id
    assert_equal image.id, std_method.docker_image_id
    assert_equal 'export_h5ad', step.name
    assert_equal 'loom_to_h5ad', std_method.name
  end

  test 'project_matrix_loom_rels returns distinct dim-3 matrix loom paths' do
    register_for_test_cleanup(
      Annot.create!(
        project_id: @project.id,
        user_id: @user.id,
        name: '/matrix',
        dim: 3,
        filepath: 'parsing/output.loom',
        nber_rows: 10,
        nber_cols: 5
      ),
      Annot.create!(
        project_id: @project.id,
        user_id: @user.id,
        name: '/col_attrs/CellID',
        dim: 1,
        filepath: 'parsing/output.loom',
        nber_rows: 1,
        nber_cols: 5
      ),
      Annot.create!(
        project_id: @project.id,
        user_id: @user.id,
        name: '/matrix',
        dim: 3,
        filepath: 'cell_filtering/output.loom',
        nber_rows: 8,
        nber_cols: 4
      ),
      Annot.create!(
        project_id: @project.id,
        user_id: @user.id,
        name: '/matrix',
        dim: 3,
        filepath: 'parsing/output.h5ad',
        nber_rows: 10,
        nber_cols: 5
      )
    )

    assert_equal(
      ['cell_filtering/output.loom', 'parsing/output.loom'],
      Basic.project_matrix_loom_rels(@project)
    )
  end

  test 'ensure_h5ad_exports_for_project starts export for each matrix loom' do
    register_for_test_cleanup(
      Annot.create!(
        project_id: @project.id,
        user_id: @user.id,
        name: '/matrix',
        dim: 3,
        filepath: 'parsing/output.loom',
        nber_rows: 10,
        nber_cols: 5
      ),
      Annot.create!(
        project_id: @project.id,
        user_id: @user.id,
        name: '/matrix',
        dim: 3,
        filepath: 'cell_filtering/output.loom',
        nber_rows: 8,
        nber_cols: 4
      )
    )
    FileUtils.mkdir_p(@project_dir + 'cell_filtering')
    File.write(@project_dir + 'cell_filtering/output.loom', 'loom-bytes')

    started = []
    Basic.stub(
      :find_or_start_h5ad_export,
      lambda { |_logger, project, loom_rel, user_id|
        assert_equal @project.id, project.id
        assert_equal @user.id, user_id
        started << loom_rel
        { run: nil, h5ad_status: 'pending', error: nil }
      }
    ) do
      results = Basic.ensure_h5ad_exports_for_project(Rails.logger, @project, @user.id)
      assert_equal 2, results.size
      assert_equal ['cell_filtering/output.loom', 'parsing/output.loom'], started.sort
    end
  end

  test 'ensure_h5ad_exports_for_project returns empty when no matrix looms' do
    results = Basic.ensure_h5ad_exports_for_project(Rails.logger, @project, @user.id)
    assert_equal [], results
  end

  test 'refresh_analysis_pipeline_for_project updates each matrix loom' do
    register_for_test_cleanup(
      Annot.create!(
        project_id: @project.id,
        user_id: @user.id,
        name: '/matrix',
        dim: 3,
        filepath: 'parsing/output.loom',
        nber_rows: 10,
        nber_cols: 5
      ),
      Annot.create!(
        project_id: @project.id,
        user_id: @user.id,
        name: '/matrix',
        dim: 3,
        filepath: 'cell_filtering/output.loom',
        nber_rows: 8,
        nber_cols: 4
      )
    )
    FileUtils.mkdir_p(@project_dir + 'cell_filtering')
    File.write(@project_dir + 'cell_filtering/output.loom', 'loom-bytes')

    called = []
    mapping_called = []
    AnalysisJsonPersistService.stub(
      :call,
      lambda { |project:, loom_filepath:|
        assert_equal @project.id, project.id
        called << loom_filepath
        { ok: true, loom_filepath: loom_filepath, annot_id: 1, nber_steps: 0 }
      }
    ) do
      AnndataMappingPersistService.stub(
        :call,
        lambda { |project:, loom_filepath:, input_group: nil|
          assert_equal @project.id, project.id
          mapping_called << loom_filepath
          { ok: true, loom_filepath: loom_filepath, annot_id: 2, x_path: '/matrix', nber_obsm: 0 }
        }
      ) do
        results = Basic.refresh_analysis_pipeline_for_project(Rails.logger, @project)
        assert_equal 2, results.size
        assert results.all? { |r| r[:ok] }
        assert_equal ['cell_filtering/output.loom', 'parsing/output.loom'], called.sort
        assert_equal ['cell_filtering/output.loom', 'parsing/output.loom'], mapping_called.sort
      end
    end
  end

  test 'refresh_analysis_pipeline_for_project returns empty when no matrix looms' do
    results = Basic.refresh_analysis_pipeline_for_project(Rails.logger, @project)
    assert_equal [], results
  end
end
