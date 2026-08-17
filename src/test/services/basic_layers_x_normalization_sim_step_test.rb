# frozen_string_literal: true

require 'test_helper'

class BasicLayersXNormalizationSimStepTest < ActiveSupport::TestCase
  setup do
    @version = Version.activated.where('id > 3').order(id: :desc).first || Version.order(id: :desc).first
    skip 'No Version available' unless @version
    skip 'No ASAP docker for version' unless Basic.get_asap_docker(@version)

    @user = register_for_test_cleanup(
      User.create!(email: "layers_x_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )
    @project = create_test_project!(
      name: 'layers X sim step',
      key: "lx#{SecureRandom.hex(3)}",
      user_id: @user.id,
      version_id: @version.id
    )
    @normalization_step_id = Basic.normalization_step_id_for_project(@project)
    skip 'No normalization step for version' unless @normalization_step_id
    @parsing_step = Step.find_by(name: 'parsing', version_id: @version.id) || Step.find_by(name: 'parsing')
    skip 'No parsing step' unless @parsing_step
    @parsing_run = Run.create!(
      project_id: @project.id,
      user_id: @user.id,
      step_id: @parsing_step.id,
      status_id: 3,
      num: 1,
      command_json: '{}',
      attrs_json: '{}',
      output_json: '{}'
    )
  end

  teardown do
    if @project&.id
      Annot.where(project_id: @project.id).delete_all
      Run.where(project_id: @project.id).delete_all
    end
  end

  test 'maps parsing /layers/X to the normalization step' do
    sim_step_id = Basic.sim_step_id_for_parsed_dataset(@parsing_run, AnndataMappingBuilder::X_LAYER_PATH)
    assert_equal @normalization_step_id, sim_step_id
  end

  test 'does not map parsing /matrix to normalization' do
    assert_nil Basic.sim_step_id_for_parsed_dataset(@parsing_run, '/matrix')
  end

  test 'keeps an existing sim_step_id' do
    other_step = Step.where.not(id: @normalization_step_id).first
    skip 'No other step' unless other_step

    sim_step_id = Basic.sim_step_id_for_parsed_dataset(
      @parsing_run,
      AnndataMappingBuilder::X_LAYER_PATH,
      existing_sim_step_id: other_step.id
    )
    assert_equal other_step.id, sim_step_id
  end

  test 'does not map /layers/X from a non-parsing run' do
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

    assert_nil Basic.sim_step_id_for_parsed_dataset(pca_run, AnndataMappingBuilder::X_LAYER_PATH)
  end

  test 'PCA source steps accept /layers/X after normalization mapping' do
    num_matrix = DataClass.find_by(name: 'num_matrix')
    skip 'No num_matrix DataClass' unless num_matrix

    annot = Annot.create!(
      project_id: @project.id,
      user_id: @user.id,
      run_id: @parsing_run.id,
      step_id: @parsing_step.id,
      filepath: 'parsing/output.loom',
      name: AnndataMappingBuilder::X_LAYER_PATH,
      dim: 3,
      nber_rows: 100,
      nber_cols: 50,
      data_class_ids: num_matrix.id.to_s,
      sim_step_id: @normalization_step_id
    )

    assert annot.matches_source_step_ids?([@normalization_step_id])
    refute annot.matches_source_step_ids?([@parsing_step.id])
  end
end
