# frozen_string_literal: true

require 'test_helper'
require 'fileutils'
require 'tmpdir'

class SelectionMetadataImportJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  def with_replaced_singleton(mod, method_name, impl)
    original = mod.method(method_name)
    mod.define_singleton_method(method_name, &impl)
    yield
  ensure
    mod.define_singleton_method(method_name, original)
  end

  setup do
    @version = Version.activated.where('id > 3').order(id: :desc).first || Version.order(id: :desc).first
    skip 'No Version available' unless @version

    parsing_step = Step.find_by(name: 'parsing', version_id: @version.id) || Step.find_by(name: 'parsing')
    skip 'No parsing step' unless parsing_step
    @step = Step.find_by(name: 'cell_selection', docker_image_id: parsing_step.docker_image_id) ||
            Step.find_by(name: 'cell_selection')
    skip 'No cell_selection step' unless @step

    @user = register_for_test_cleanup(
      User.create!(email: "seljob_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )
    @project = create_test_project!(
      name: 'Selection import',
      key: "sel#{SecureRandom.hex(3)}",
      user_id: @user.id,
      version_id: @version.id
    )
    @run = Run.create!(
      project_id: @project.id,
      user_id: @user.id,
      step_id: @step.id,
      status_id: 1,
      num: 1,
      command_json: '{}',
      attrs_json: {
        loom_file: 'parsing/output.loom',
        selection_metadata_name: '/col_attrs/X_umap.sel_1',
        selected_cells_file: nil,
        selected_name: 'T cells',
        unselected_name: 'Not selected'
      }.to_json,
      output_json: '{}'
    )
    @original_user_data_dir = ENV['USER_DATA_DIR']
    @data_dir = Dir.mktmpdir('asap_sel_job')
    ENV['USER_DATA_DIR'] = @data_dir
    @project_dir = Pathname.new(@data_dir) + @user.id.to_s + @project.key
    FileUtils.mkdir_p(@project_dir + 'parsing')
    FileUtils.mkdir_p(@project_dir + 'metadata' + @run.id.to_s)
    File.write(@project_dir + 'parsing' + 'output.loom', 'loom')
    selected_file = @project_dir + 'metadata' + @run.id.to_s + 'selected_cells.json'
    File.write(selected_file, { selected_indices: [0, 2] }.to_json)
    attrs = Basic.safe_parse_json(@run.attrs_json, {})
    attrs['selected_cells_file'] = selected_file.to_s
    @run.update!(attrs_json: attrs.to_json)
    @annot = Annot.create!(
      project_id: @project.id,
      user_id: @user.id,
      run_id: @run.id,
      filepath: 'parsing/output.loom',
      name: '/col_attrs/X_umap.sel_1',
      dim: 1,
      nber_cols: 4,
      nber_rows: 1
    )
  end

  teardown do
    if @project&.id
      Cla.where(project_id: @project.id).delete_all
      Annot.where(project_id: @project.id).delete_all
      Run.where(project_id: @project.id).delete_all
      ProjectStep.where(project_id: @project.id).delete_all
    end
    FileUtils.rm_rf(@data_dir) if @data_dir && File.exist?(@data_dir)
    ENV['USER_DATA_DIR'] = @original_user_data_dir if @original_user_data_dir
  end

  test 'perform writes via h5py and marks the run completed' do
    written = []
    meta = {
      'name' => '/col_attrs/X_umap.sel_1',
      'on' => 'CELL',
      'type' => 'DISCRETE',
      'nber_cols' => 4,
      'nber_rows' => 1,
      'categories' => { '0' => 2, '1' => 2 }
    }

    empty_clas = Object.new
    def empty_clas.first
      nil
    end

    with_replaced_singleton(H5DataService, :write_cell_selection!, lambda { |*args, **|
      written.replace(args)
      meta
    }) do
      with_replaced_singleton(Basic, :load_annot, lambda { |*| @annot }) do
        with_replaced_singleton(Basic, :upd_project_step, lambda { |*| }) do
          with_replaced_singleton(Cla, :where, lambda { |*_args, **_kwargs| empty_clas }) do
            with_replaced_singleton(Cla, :create, lambda { |*_args, **_kwargs| Cla.new }) do
              SelectionMetadataImportJob.perform_now(@run.id)
            end
          end
        end
      end
    end

    @run.reload
    assert_equal 3, @run.status_id
    assert_equal 3, written.length
    assert_match(/output\.loom\z/, written[0].to_s)
    assert_equal '/col_attrs/X_umap.sel_1', written[1]
  end

  test 'perform records a failed status when the write raises' do
    with_replaced_singleton(H5DataService, :write_cell_selection!, lambda { |*|
      raise 'Cell index 99 is out of range (n=5)'
    }) do
      with_replaced_singleton(Basic, :upd_project_step, lambda { |*| }) do
        SelectionMetadataImportJob.perform_now(@run.id)
      end
    end

    @run.reload
    assert_equal 4, @run.status_id
    assert_equal 'Cell index 99 is out of range (n=5)', @run.error
  end
end
