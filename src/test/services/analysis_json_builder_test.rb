# frozen_string_literal: true

require 'test_helper'

class AnalysisJsonBuilderTest < ActiveSupport::TestCase
  test 'builds scFAIR analysis_json document from successful loom runs' do
    user = register_for_test_cleanup(User.create!(email: "ajb_#{SecureRandom.hex(4)}@example.com", password: 'password123'))
    project = create_test_project!(user_id: user.id, input_filename: 'input_file.h5ad')
    success = Status.find_by(name: 'success')
    assert success, 'statuses.success fixture/row is required'

    docker_image = DockerImage.order(:id).first
    if docker_image
      tools = Basic.safe_parse_json(docker_image.tools_json, {})
      docker_image.update_columns(tools_json: tools.merge('java' => '17.0.19').to_json)
      docker_image.reload
    end
    step = register_for_test_cleanup(
      Step.create!(
        name: 'parsing',
        label: 'Parsing',
        rank: 1,
        docker_image_id: docker_image&.id
      )
    )

    std = register_for_test_cleanup(
      StdMethod.create!(
        name: "parsing_aj_#{SecureRandom.hex(4)}",
        label: 'Parsing',
        step_id: step.id,
        docker_image_id: docker_image&.id,
        command_json: { 'program' => 'java -jar ASAP.jar' }.to_json,
        description: 'Parse input into loom'
      )
    )

    digest = 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    docker_build = nil
    if docker_image
      docker_build = register_for_test_cleanup(
        DockerBuild.create!(
          docker_image_id: docker_image.id,
          tag: docker_image.tag.to_s,
          digest: digest
        )
      )
    end

    run = register_for_test_cleanup(
      Run.create!(
        project_id: project.id,
        step_id: step.id,
        std_method_id: std.id,
        status_id: success.id,
        user_id: user.id,
        start_time: Time.utc(2026, 1, 2, 3, 4, 5),
        duration: 12.5,
        nber_cores: 4,
        max_ram: 2048.0,
        docker_build_id: docker_build&.id,
        command_json: {
          'program' => 'java -jar ASAP.jar',
          'opts' => [
            { 'opt' => '-T', 'param_key' => 'tool', 'value' => 'Parsing' },
            { 'opt' => '-loom', 'param_key' => 'loom_filename', 'value' => 'parsing/output.loom' }
          ],
          'args' => []
        }.to_json,
        attrs_json: { 'nber_cols' => '100', 'seed' => '42' }.to_json,
        output_json: {
          'output_matrix' => {
            'parsing/output.loom:/matrix' => {
              'onum' => 1,
              'filename' => 'output.loom',
              'dataset' => '/matrix'
            }
          }
        }.to_json,
        lineage_run_ids: ''
      )
    )

    register_for_test_cleanup(
      Annot.create!(
        project_id: project.id,
        run_id: run.id,
        store_run_id: run.id,
        ori_run_id: run.id,
        step_id: step.id,
        filepath: 'parsing/output.loom',
        name: '/matrix',
        dim: 3,
        data_type_id: DataType.find_by(name: 'NUMERIC')&.id || 1,
        user_id: user.id,
        latest_version: true,
        version_nber: 1
      )
    )

    doc = AnalysisJsonBuilder.call(project: project, loom_filepath: 'parsing/output.loom')

    assert_equal AnalysisJsonBuilder::SCHEMA_VERSION, doc['schema_version']
    assert_equal 'ASAP', doc['pipeline_name']
    assert_kind_of Array, doc['steps']
    assert_equal 1, doc['steps'].size

    step_doc = doc['steps'].first
    assert_equal "Parsing [#{run.id}]", step_doc['step_label']
    assert_equal 'Parsing', step_doc['step_category']
    assert_includes step_doc['command'], 'java -jar ASAP.jar'
    assert_equal 42, step_doc['random_seed']
    assert_equal 4, step_doc['resources']['cpu']
    assert_in_delta 2.0, step_doc['resources']['memory_gb'], 0.0001
    assert_equal 'Java', step_doc['programming_language']
    assert_equal '17.0.19', step_doc['programming_language_version']
    assert_equal digest, step_doc['docker_image_digest']
    assert step_doc['parameters'].any? { |p| p['name'] == 'tool' && p['value'] == 'Parsing' }
    assert step_doc['outputs'].any? { |o| o['location'] == '/matrix' }
    assert step_doc['inputs'].any? { |i| i['label'] == 'input_filename' && i['location'] == 'input_file.h5ad' }
  end

  test 'adds integration source looms as parsing inputs' do
    user = register_for_test_cleanup(User.create!(email: "ajb4_#{SecureRandom.hex(4)}@example.com", password: 'password123'))
    source_a = create_test_project!(user_id: user.id, key: "sa#{SecureRandom.hex(3)}")
    source_b = create_test_project!(user_id: user.id, key: "sb#{SecureRandom.hex(3)}")
    project = create_test_project!(user_id: user.id)
    success = Status.find_by(name: 'success')
    assert success

    docker_image = DockerImage.order(:id).first
    step = register_for_test_cleanup(
      Step.create!(
        name: 'parsing',
        label: 'Parsing',
        rank: 1,
        docker_image_id: docker_image&.id
      )
    )
    std = register_for_test_cleanup(
      StdMethod.create!(
        name: "integration_aj_#{SecureRandom.hex(4)}",
        label: 'Integration',
        step_id: step.id,
        docker_image_id: docker_image&.id,
        command_json: { 'program' => 'rails integrate' }.to_json
      )
    )

    run = register_for_test_cleanup(
      Run.create!(
        project_id: project.id,
        step_id: step.id,
        std_method_id: std.id,
        status_id: success.id,
        user_id: user.id,
        command_json: {
          'program' => "rails integrate[#{project.key}]",
          'opts' => [],
          'args' => []
        }.to_json,
        attrs_json: {
          'integrate_method' => 'harmony',
          'integrate_source_keys' => [source_a.key, source_b.key]
        }.to_json,
        output_json: {
          'output_matrix' => {
            'parsing/output.loom:/matrix' => {
              'onum' => 1,
              'filename' => 'output.loom',
              'dataset' => '/matrix'
            }
          }
        }.to_json,
        lineage_run_ids: ''
      )
    )
    register_for_test_cleanup(
      Annot.create!(
        project_id: project.id,
        run_id: run.id,
        store_run_id: run.id,
        ori_run_id: run.id,
        step_id: step.id,
        filepath: 'parsing/output.loom',
        name: '/matrix',
        dim: 3,
        data_type_id: DataType.find_by(name: 'NUMERIC')&.id || 1,
        user_id: user.id,
        latest_version: true,
        version_nber: 1
      )
    )

    doc = AnalysisJsonBuilder.call(project: project, loom_filepath: 'parsing/output.loom')
    step_doc = doc['steps'].first
    assert step_doc

    data_root = ENV.fetch('USER_DATA_DIR')
    expected_a = "#{data_root}/#{user.id}/#{source_a.key}/parsing/output.loom"
    expected_b = "#{data_root}/#{user.id}/#{source_b.key}/parsing/output.loom"
    assert step_doc['inputs'].any? { |i| i['label'] == "integrate_source:#{source_a.key}" && i['location'] == expected_a }
    assert step_doc['inputs'].any? { |i| i['label'] == "integrate_source:#{source_b.key}" && i['location'] == expected_b }
  end

  test 'returns empty steps when loom has no annot-linked runs' do
    user = register_for_test_cleanup(User.create!(email: "ajb2_#{SecureRandom.hex(4)}@example.com", password: 'password123'))
    project = create_test_project!(user_id: user.id)
    doc = AnalysisJsonBuilder.call(project: project, loom_filepath: 'parsing/output.loom')
    assert_equal [], doc['steps']
  end

  test 'relativizes absolute paths from another data root to project-relative paths' do
    user = register_for_test_cleanup(User.create!(email: "ajb3_#{SecureRandom.hex(4)}@example.com", password: 'password123'))
    project = create_test_project!(user_id: user.id)
    success = Status.find_by(name: 'success')
    assert success

    docker_image = DockerImage.order(:id).first
    step = register_for_test_cleanup(
      Step.create!(
        name: 'normalization',
        label: 'Normalization',
        rank: 11,
        docker_image_id: docker_image&.id
      )
    )
    std = register_for_test_cleanup(
      StdMethod.create!(
        name: "norm_aj_#{SecureRandom.hex(4)}",
        label: 'Normalization',
        step_id: step.id,
        docker_image_id: docker_image&.id,
        command_json: { 'program' => 'Rscript norm.R' }.to_json
      )
    )

    foreign_loom = "/data/asap/users/#{user.id}/#{project.key}/parsing/output.loom"
    foreign_outdir = "/data/asap/users/#{user.id}/#{project.key}/normalization/12"
    run = register_for_test_cleanup(
      Run.create!(
        project_id: project.id,
        step_id: step.id,
        std_method_id: std.id,
        status_id: success.id,
        user_id: user.id,
        command_json: {
          'program' => 'Rscript norm.R',
          'opts' => [
            { 'opt' => '-f', 'param_key' => 'input_matrix_filename', 'value' => foreign_loom },
            { 'opt' => '-o', 'param_key' => 'output_dir', 'value' => foreign_outdir }
          ],
          'args' => []
        }.to_json,
        attrs_json: { 'input_matrix_filename' => foreign_loom }.to_json,
        output_json: {
          'output_json' => {
            "#{foreign_outdir}/output.json" => { 'onum' => 1, 'filename' => 'output.json' }
          }
        }.to_json,
        lineage_run_ids: ''
      )
    )
    register_for_test_cleanup(
      Annot.create!(
        project_id: project.id,
        run_id: run.id,
        store_run_id: run.id,
        filepath: 'parsing/output.loom',
        name: '/layers/norm',
        dim: 3,
        data_type_id: DataType.find_by(name: 'NUMERIC')&.id || 1,
        user_id: user.id,
        latest_version: true,
        version_nber: 1
      )
    )

    doc = AnalysisJsonBuilder.call(project: project, loom_filepath: 'parsing/output.loom')
    step_doc = doc['steps'].first
    assert step_doc

    json = JSON.generate(doc)
    refute_match(/\.\.\//, json)
    assert_includes step_doc['command'], 'parsing/output.loom'
    refute_includes step_doc['command'], '/data/asap/'
    assert step_doc['inputs'].any? { |i| i['location'] == 'parsing/output.loom' }
    assert step_doc['outputs'].any? { |o| o['location'] == 'normalization/12/output.json' }
    assert step_doc['parameters'].any? { |p| p['name'] == 'input_matrix_filename' && p['value'] == 'parsing/output.loom' }
  end

  test 'converts legacy kilobyte max_ram values to memory_gb' do
    user = register_for_test_cleanup(User.create!(email: "ajb5_#{SecureRandom.hex(4)}@example.com", password: 'password123'))
    project = create_test_project!(user_id: user.id)
    success = Status.find_by(name: 'success')
    assert success

    docker_image = DockerImage.order(:id).first
    step = register_for_test_cleanup(
      Step.create!(
        name: 'normalization',
        label: 'Normalization',
        rank: 11,
        docker_image_id: docker_image&.id
      )
    )
    std = register_for_test_cleanup(
      StdMethod.create!(
        name: "norm_ram_#{SecureRandom.hex(4)}",
        label: 'Normalization',
        step_id: step.id,
        docker_image_id: docker_image&.id,
        command_json: { 'program' => 'Rscript norm.R' }.to_json
      )
    )

    # Legacy GNU time %M kilobytes (1.3223 GB), stored before MB conversion.
    run = register_for_test_cleanup(
      Run.create!(
        project_id: project.id,
        step_id: step.id,
        std_method_id: std.id,
        status_id: success.id,
        user_id: user.id,
        max_ram: 1_386_572.0,
        command_json: { 'program' => 'Rscript norm.R', 'opts' => [], 'args' => [] }.to_json,
        attrs_json: {}.to_json,
        output_json: {
          'output_json' => {
            'normalization/1/output.json' => { 'onum' => 1, 'filename' => 'output.json' }
          }
        }.to_json,
        lineage_run_ids: ''
      )
    )
    run.update_columns(created_at: Time.utc(2021, 6, 11, 14, 7, 43))
    run.reload
    register_for_test_cleanup(
      Annot.create!(
        project_id: project.id,
        run_id: run.id,
        store_run_id: run.id,
        filepath: 'parsing/output.loom',
        name: '/layers/norm',
        dim: 3,
        data_type_id: DataType.find_by(name: 'NUMERIC')&.id || 1,
        user_id: user.id,
        latest_version: true,
        version_nber: 1
      )
    )

    doc = AnalysisJsonBuilder.call(project: project, loom_filepath: 'parsing/output.loom')
    step_doc = doc['steps'].first
    assert step_doc
    assert_in_delta 1.3223, step_doc['resources']['memory_gb'], 0.0001
  end
end
