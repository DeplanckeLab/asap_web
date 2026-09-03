require_relative "test_base_without_fixtures"
require "fileutils"

class ProjectCloneServiceTest < TestBaseWithoutFixtures
  setup do
    @tmp_root = Dir.mktmpdir("project-clone-service")
    @previous_user_data_dir = ENV["USER_DATA_DIR"]
    ENV["USER_DATA_DIR"] = File.join(@tmp_root, "projects")
    FileUtils.mkdir_p(ENV["USER_DATA_DIR"])
  end

  teardown do
    # Destroy test-created DB rows while temp USER_DATA_DIR is still set.
    destroy_registered_test_records!
    ENV["USER_DATA_DIR"] = @previous_user_data_dir
    FileUtils.rm_rf(@tmp_root) if @tmp_root.present?
  end

  test "clone keeps shared fu_id and copies fus directory under new project key" do
    user = register_for_test_cleanup(User.create!(email: "clone_fu_#{SecureRandom.hex(4)}@example.com", password: "password123"))
    source = create_test_project!(
      name: "Source project",
      key: "src#{SecureRandom.hex(3)}",
      user_id: user.id
    )
    source_fu = register_for_test_cleanup(Fu.create!(
      project_id: source.id,
      project_key: source.key,
      user_id: user.id,
      upload_file_name: "input_file.rds",
      upload_file_size: 4,
      status: "completed"
    ))
    source.update_columns(fu_id: source_fu.id)

    source_upload_dir = source_fu.upload_dir
    FileUtils.mkdir_p(source_upload_dir)
    File.write(source_upload_dir + source_fu.upload_file_name, "test")

    source_dir = Pathname.new(ENV["USER_DATA_DIR"]) + user.id.to_s + source.key
    FileUtils.mkdir_p(source_dir + "fus" + source_fu.id.to_s)
    File.write(source_dir + "input_file.rds", "canonical")

    service = ProjectCloneService.new(source, user: user, session: {})
    clone = service.call
    assert clone, "Expected clone to succeed: #{service.errors.inspect}"
    register_for_test_cleanup(clone)

    assert_equal source_fu.id, clone.fu_id
    clone_upload_dir = source_fu.upload_dir_for_project(clone)
    assert File.exist?(clone_upload_dir + source_fu.upload_file_name),
           "Expected cloned upload file at #{clone_upload_dir}"
  end

  test "clone assigns a unique key even when source and clone share an owner" do
    user = register_for_test_cleanup(User.create!(email: "clone_key_#{SecureRandom.hex(4)}@example.com", password: "password123"))
    source = create_test_project!(
      name: "Source project",
      key: "src#{SecureRandom.hex(3)}",
      user_id: user.id
    )

    source_dir = Pathname.new(ENV["USER_DATA_DIR"]) + user.id.to_s + source.key
    FileUtils.mkdir_p(source_dir)

    service = ProjectCloneService.new(source, user: user, session: {})
    clone = service.call
    assert clone, "Expected clone to succeed: #{service.errors.inspect}"
    register_for_test_cleanup(clone)

    assert_not_equal source.key, clone.key
    assert_not Project.where(key: source.key).where.not(id: source.id).exists?
  end

  test "upload_dir_for_project uses clone path when fu row points at source project" do
    user = register_for_test_cleanup(User.create!(email: "fu_scope_#{SecureRandom.hex(4)}@example.com", password: "password123"))
    source = create_test_project!(name: "Scope source", key: "scp#{SecureRandom.hex(3)}", user_id: user.id)
    fu = register_for_test_cleanup(Fu.create!(
      project_id: source.id,
      project_key: source.key,
      upload_file_name: "input_file.rds"
    ))
    clone = create_test_project!(
      name: "Scope clone",
      key: "cln#{SecureRandom.hex(3)}",
      user_id: user.id,
      fu_id: fu.id,
      cloned_project_id: source.id
    )

    source_dir = fu.upload_dir
    clone_dir = fu.upload_dir_for_project(clone)
    assert_includes source_dir.to_s, "/#{source.key}/fus/#{fu.id}"
    assert_includes clone_dir.to_s, "/#{clone.key}/fus/#{fu.id}"
    assert_not_equal source_dir.to_s, clone_dir.to_s
  end

  test "start! refuses admin_report_only project types for other users" do
    spat = ProjectType.find_by(tag: "spat") || ProjectType.ensure_for_tag!("spat")
    spat.update!(admin_report_only: true)
    user = register_for_test_cleanup(
      User.create!(email: "clone_deny_#{SecureRandom.hex(4)}@example.com", password: "password123")
    )
    source = create_test_project!(
      name: "Restricted clone source",
      key: "rsc#{SecureRandom.hex(3)}",
      user_id: user.id,
      project_type_id: spat.id
    )

    previous = ENV["ADMIN_REPORT_EMAILS"]
    ENV["ADMIN_REPORT_EMAILS"] = "admin-report@example.com"
    service = ProjectCloneService.new(source, user: user, session: {})
    clone = service.start!
    assert_nil clone
    assert_includes service.errors, "This project type is not available"
  ensure
    if previous.nil?
      ENV.delete("ADMIN_REPORT_EMAILS")
    else
      ENV["ADMIN_REPORT_EMAILS"] = previous
    end
    spat&.update!(admin_report_only: true)
  end

  test "start! allows admin_report_only project types for ADMIN_REPORT_EMAILS users" do
    spat = ProjectType.find_by(tag: "spat") || ProjectType.ensure_for_tag!("spat")
    spat.update!(admin_report_only: true)
    email = "clone_ok_#{SecureRandom.hex(4)}@example.com"
    user = register_for_test_cleanup(
      User.create!(email: email, password: "password123")
    )
    source = create_test_project!(
      name: "Restricted clone allowed",
      key: "rca#{SecureRandom.hex(3)}",
      user_id: user.id,
      project_type_id: spat.id
    )

    previous = ENV["ADMIN_REPORT_EMAILS"]
    ENV["ADMIN_REPORT_EMAILS"] = email
    service = ProjectCloneService.new(source, user: user, session: {})
    clone = service.start!
    assert clone, "Expected clone start to succeed: #{service.errors.inspect}"
    register_for_test_cleanup(clone)
    assert_equal spat.id, clone.project_type_id
  ensure
    if previous.nil?
      ENV.delete("ADMIN_REPORT_EMAILS")
    else
      ENV["ADMIN_REPORT_EMAILS"] = previous
    end
    spat&.update!(admin_report_only: true)
  end

  test "complete! overwrites project_steps created concurrently during clone" do
    user = register_for_test_cleanup(User.create!(email: "clone_ps_#{SecureRandom.hex(4)}@example.com", password: "password123"))
    source = create_test_project!(
      name: "Source project steps",
      key: "sps#{SecureRandom.hex(3)}",
      user_id: user.id,
      version_id: 8
    )
    step = Step.find_by!(name: "parsing", version_id: 8)
    register_for_test_cleanup(
      ProjectStep.create!(
        project_id: source.id,
        step_id: step.id,
        status_id: 3,
        nber_runs_json: '{"3":1}'
      )
    )

    source_dir = Pathname.new(ENV["USER_DATA_DIR"]) + user.id.to_s + source.key
    FileUtils.mkdir_p(source_dir)

    service = ProjectCloneService.new(source, user: user, session: {})
    clone = service.start!
    assert clone, "Expected clone start to succeed: #{service.errors.inspect}"
    register_for_test_cleanup(clone)

    # Mimic show#ensure_project_steps racing after reset_partial_clone! cleared steps.
    service.send(:reset_partial_clone!)
    ProjectStep.create!(
      project_id: clone.id,
      step_id: step.id,
      status_id: 1,
      nber_runs_json: '{}'
    )

    service.send(:copy_project_steps)

    cloned_ps = ProjectStep.find_by!(project_id: clone.id, step_id: step.id)
    assert_equal 3, cloned_ps.status_id
    assert_equal '{"3":1}', cloned_ps.nber_runs_json
  end

  test "ensure_project_steps does nothing while being_cloned" do
    user = register_for_test_cleanup(User.create!(email: "clone_ens_#{SecureRandom.hex(4)}@example.com", password: "password123"))
    project = create_test_project!(
      name: "Being cloned",
      key: "bcl#{SecureRandom.hex(3)}",
      user_id: user.id,
      version_id: 8,
      being_cloned: true
    )

    assert_no_difference -> { ProjectStep.where(project_id: project.id).count } do
      project.ensure_project_steps
    end
  end

  test "clone copies visualization and heatmap checkpoints with remapped ids" do
    user = register_for_test_cleanup(User.create!(email: "clone_ckpt_#{SecureRandom.hex(4)}@example.com", password: "password123"))
    source = create_test_project!(
      name: "Checkpoint source",
      key: "cks#{SecureRandom.hex(3)}",
      user_id: user.id,
      version_id: 8
    )
    step = Step.find_by!(name: "parsing", version_id: 8)
    source_run = register_for_test_cleanup(
      Run.create!(project_id: source.id, user_id: user.id, step_id: step.id, status_id: 1, num: 1)
    )
    embedding = register_for_test_cleanup(
      Annot.create!(
        project_id: source.id,
        user_id: user.id,
        run_id: source_run.id,
        store_run_id: source_run.id,
        filepath: "dim_reduction/#{source_run.id}/output.loom",
        name: "/col_attrs/X_umap",
        dim: 1,
        nber_rows: 2,
        nber_cols: 100,
        latest_version: true,
        version_nber: 1
      )
    )
    coloring = register_for_test_cleanup(
      Annot.create!(
        project_id: source.id,
        user_id: user.id,
        run_id: source_run.id,
        store_run_id: source_run.id,
        filepath: "dim_reduction/#{source_run.id}/output.loom",
        name: "/col_attrs/cell_type",
        dim: 1,
        nber_cols: 100,
        latest_version: true,
        version_nber: 1
      )
    )

    viz_state = {
      "version" => 1,
      "loomFile" => "dim_reduction/#{source_run.id}/output.loom",
      "embedding" => { "id" => embedding.id.to_s, "loomFile" => "dim_reduction/#{source_run.id}/output.loom" },
      "visualizationEmbedding" => {
        "id" => embedding.id.to_s,
        "loomFile" => "dim_reduction/#{source_run.id}/output.loom",
        "name" => embedding.name
      },
      "matrix" => { "layer" => nil, "annotId" => coloring.id },
      "coloring" => {
        "metadataId" => coloring.id.to_s,
        "metadataGradients" => { coloring.id.to_s => { "gradientScale" => "normal" } }
      },
      "filters" => {
        "selectedCategories" => { coloring.id.to_s => ["T cell"] },
        "selectedRanges" => {},
        "metadataFilterSwitches" => {},
        "geneFilterSwitches" => {},
        "globalFiltersEnabled" => true
      }
    }
    heatmap_state = {
      "version" => 1,
      "kind" => "heatmap",
      "run_id" => source_run.id,
      "colTracks" => [{ "id" => coloring.id.to_s, "type" => "categorical" }],
      "rowTracks" => []
    }

    viz_checkpoint = register_for_test_cleanup(
      Checkpoint.create!(
        project: source,
        user: user,
        title: "Landing UMAP",
        kind: Checkpoint::KIND_VISUALIZATION,
        is_landing_page: true,
        state: viz_state
      )
    )
    heatmap_checkpoint = register_for_test_cleanup(
      Checkpoint.create!(
        project: source,
        user: user,
        title: "Heatmap view",
        kind: Checkpoint::KIND_HEATMAP,
        run_id: source_run.id,
        state: heatmap_state
      )
    )
    register_for_test_cleanup(
      Checkpoint.create!(
        project: source,
        user: user,
        title: Checkpoint::CURRENT_VISUALIZATION_TITLE,
        kind: Checkpoint::KIND_VISUALIZATION,
        state: { "version" => 1, "loomFile" => "parsing/output.loom" }
      )
    )

    source_dir = Pathname.new(ENV["USER_DATA_DIR"]) + user.id.to_s + source.key
    FileUtils.mkdir_p(source_dir + "dim_reduction" + source_run.id.to_s)
    File.write(source_dir + "dim_reduction" + source_run.id.to_s + "output.loom", "loom")

    service = ProjectCloneService.new(source, user: user, session: {})
    clone = service.call
    assert clone, "Expected clone to succeed: #{service.errors.inspect}"
    register_for_test_cleanup(clone)

    cloned_run = clone.runs.find_by!(cloned_run_id: source_run.id)
    cloned_embedding = clone.annots.find_by!(name: embedding.name)
    cloned_coloring = clone.annots.find_by!(name: coloring.name)

    assert_equal 3, clone.checkpoints.count

    cloned_viz = clone.checkpoints.find_by!(title: viz_checkpoint.title, kind: Checkpoint::KIND_VISUALIZATION)
    assert cloned_viz.is_landing_page?
    assert_nil cloned_viz.run_id
    assert_equal "dim_reduction/#{cloned_run.id}/output.loom", cloned_viz.state["loomFile"]
    assert_equal cloned_embedding.id.to_s, cloned_viz.state.dig("embedding", "id")
    assert_equal cloned_embedding.id.to_s, cloned_viz.state.dig("visualizationEmbedding", "id")
    assert_equal cloned_coloring.id, cloned_viz.state.dig("matrix", "annotId")
    assert_equal cloned_coloring.id.to_s, cloned_viz.state.dig("coloring", "metadataId")
    assert cloned_viz.state.dig("coloring", "metadataGradients").key?(cloned_coloring.id.to_s)
    assert_equal ["T cell"], cloned_viz.state.dig("filters", "selectedCategories", cloned_coloring.id.to_s)

    cloned_heatmap = clone.checkpoints.find_by!(title: heatmap_checkpoint.title, kind: Checkpoint::KIND_HEATMAP)
    assert_equal cloned_run.id, cloned_heatmap.run_id
    assert_equal cloned_run.id, cloned_heatmap.state["run_id"]
    assert_equal cloned_coloring.id.to_s, cloned_heatmap.state.dig("colTracks", 0, "id")

    assert clone.checkpoints.exists?(title: Checkpoint::CURRENT_VISUALIZATION_TITLE)
  end
end
