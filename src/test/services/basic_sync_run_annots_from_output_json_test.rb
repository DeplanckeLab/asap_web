# frozen_string_literal: true

require 'minitest/mock'
require 'tmpdir'
require 'fileutils'
require_relative 'test_base_without_fixtures'

class BasicSyncRunAnnotsFromOutputJsonTest < TestBaseWithoutFixtures
  setup do
    suffix = SecureRandom.hex(4)
    @user = register_for_test_cleanup(
      User.create!(email: "sync_dims_#{suffix}@example.com", password: 'password123')
    )
    @project = create_test_project!(
      name: "Sync dims #{suffix}",
      key: "sd#{suffix[0, 6]}",
      user_id: @user.id
    )
    success = Status.find_by(name: 'success')
    assert success, 'statuses.success is required'

    @step = Step.find_by(name: 'parsing') || Step.order(:id).first
    assert @step, 'a step row is required'
    @run = register_for_test_cleanup(
      Run.create!(
        project_id: @project.id,
        step_id: @step.id,
        status_id: success.id,
        user_id: @user.id,
        lineage_run_ids: ''
      )
    )

    numeric_id = DataType.find_by(name: 'NUMERIC')&.id || 1
    discrete_id = DataType.find_by(name: 'DISCRETE')&.id || 3
    string_id = DataType.find_by(name: 'STRING')&.id || 2

    # Simulate corruption: vector annots wrongly given matrix shape (27998 x 2919).
    @gene_annot = register_for_test_cleanup(
      Annot.create!(
        project_id: @project.id,
        run_id: @run.id,
        store_run_id: @run.id,
        ori_run_id: @run.id,
        step_id: @step.id,
        filepath: 'parsing/output.loom',
        name: '/row_attrs/feature_biotype',
        dim: 2,
        data_type_id: discrete_id,
        nber_rows: 27998,
        nber_cols: 2919,
        user_id: @user.id,
        latest_version: true,
        version_nber: 1
      )
    )
    @cell_annot = register_for_test_cleanup(
      Annot.create!(
        project_id: @project.id,
        run_id: @run.id,
        store_run_id: @run.id,
        ori_run_id: @run.id,
        step_id: @step.id,
        filepath: 'parsing/output.loom',
        name: '/col_attrs/CellID',
        dim: 1,
        data_type_id: string_id,
        nber_rows: 27998,
        nber_cols: 2919,
        user_id: @user.id,
        latest_version: true,
        version_nber: 1
      )
    )
    @matrix_annot = register_for_test_cleanup(
      Annot.create!(
        project_id: @project.id,
        run_id: @run.id,
        store_run_id: @run.id,
        ori_run_id: @run.id,
        step_id: @step.id,
        filepath: 'parsing/output.loom',
        name: '/matrix',
        dim: 3,
        data_type_id: numeric_id,
        nber_rows: 27998,
        nber_cols: 2919,
        user_id: @user.id,
        latest_version: true,
        version_nber: 1
      )
    )

    @tmpdir = Dir.mktmpdir("sync_dims_#{suffix}")
    File.write(
      File.join(@tmpdir, 'output.json'),
      {
        'nber_rows' => 27998,
        'nber_cols' => 2919,
        'metadata' => [
          {
            'name' => '/row_attrs/feature_biotype',
            'on' => 'GENE',
            'type' => 'DISCRETE',
            'nber_rows' => 27998,
            'nber_cols' => 1
          },
          {
            'name' => '/col_attrs/CellID',
            'on' => 'CELL',
            'type' => 'STRING',
            'nber_rows' => 1,
            'nber_cols' => 2919
          }
        ]
      }.to_json
    )
  end

  teardown do
    FileUtils.remove_entry(@tmpdir) if @tmpdir && File.directory?(@tmpdir)
    [@matrix_annot, @cell_annot, @gene_annot].each { |a| a.destroy! if a&.persisted? }
    @run.destroy! if @run&.persisted?
    DelRun.where(user_id: @user.id).delete_all if @user
  end

  test 'sync uses per-metadata dims not top-level matrix shape' do
    logger = Logger.new(File::NULL)

    Basic.stub(:run_output_dir, ->(_run) { Pathname.new(@tmpdir) }) do
      assert Basic.sync_run_annots_from_output_json!(logger, @run)
    end

    @gene_annot.reload
    @cell_annot.reload
    @matrix_annot.reload

    assert_equal 27998, @gene_annot.nber_rows
    assert_equal 1, @gene_annot.nber_cols
    assert_equal 1, @cell_annot.nber_rows
    assert_equal 2919, @cell_annot.nber_cols
    # /matrix is not in metadata[]; sync must not change it via top-level dims alone
    assert_equal 27998, @matrix_annot.nber_rows
    assert_equal 2919, @matrix_annot.nber_cols
  end

  test 'dry_run reports changes without writing' do
    logger = Logger.new(File::NULL)

    Basic.stub(:run_output_dir, ->(_run) { Pathname.new(@tmpdir) }) do
      plan = Basic.plan_sync_run_annots_from_output_json(@run)
      assert plan
      assert_equal 2, plan[:changes].size
      assert Basic.sync_run_annots_from_output_json!(logger, @run, dry_run: true)
    end

    @gene_annot.reload
    @cell_annot.reload
    assert_equal 2919, @gene_annot.nber_cols
    assert_equal 27998, @cell_annot.nber_rows
  end
end
