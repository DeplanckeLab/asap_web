require_relative "../services/test_base_without_fixtures"
require "fileutils"

class ProjectTest < TestBaseWithoutFixtures
  test "destroy removes project directory and local archive tgz under USER_DATA_DIR" do
    tmp_root = Dir.mktmpdir("project-destroy-fs")
    previous_user_data_dir = ENV["USER_DATA_DIR"]
    ENV["USER_DATA_DIR"] = File.join(tmp_root, "projects")
    FileUtils.mkdir_p(ENV["USER_DATA_DIR"])

    begin
      user = register_for_test_cleanup(
        User.create!(email: "proj_destroy_fs_#{SecureRandom.hex(4)}@example.com", password: "password123")
      )
      project = create_test_project!(
        name: "Destroy filesystem",
        key: "dfs#{SecureRandom.hex(3)}",
        user_id: user.id
      )

      project_dir = project.data_dir
      archive_file = Pathname.new("#{project_dir}.tgz")
      FileUtils.mkdir_p(project_dir + "fus" + "1")
      File.write(project_dir + "input_file", "data")
      File.write(archive_file, "tgz")

      assert File.directory?(project_dir.to_s)
      assert File.exist?(archive_file.to_s)

      project.destroy!
      @records_for_test_cleanup.delete(project)

      assert_not File.exist?(project_dir.to_s), "Expected project dir to be removed: #{project_dir}"
      assert_not File.exist?(archive_file.to_s), "Expected archive tgz to be removed: #{archive_file}"
    ensure
      ENV["USER_DATA_DIR"] = previous_user_data_dir
      FileUtils.rm_rf(tmp_root) if tmp_root.present?
    end
  end

  test "update_archive_metadata does not touch updated_at" do
    project = create_test_project!(name: "Archive metadata", key: "arc#{SecureRandom.hex(3)}")
    original_updated_at = project.updated_at

    travel 1.second do
      project.update_archive_metadata!(archive_status_id: 3, disk_size_archived: 1234)
    end

    project.reload
    assert_equal 3, project.archive_status_id
    assert_equal 1234, project.disk_size_archived
    assert_equal original_updated_at.to_i, project.updated_at.to_i
  end

  test "update_archive_metadata rejects non-archive fields" do
    project = create_test_project!(name: "Archive reject", key: "rej#{SecureRandom.hex(3)}")

    error = assert_raises(ArgumentError) do
      project.update_archive_metadata!(archive_status_id: 3, name: "bad")
    end

    assert_match(/Unsupported archive metadata fields/, error.message)
  end

  test "archive_availability_state distinguishes archived from plain missing data" do
    project = create_test_project!(name: "Archive state", key: "sta#{SecureRandom.hex(3)}")

    project.archive_status_id = 1
    project.define_singleton_method(:filesystem_project_data_missing?) { true }
    project.define_singleton_method(:archive_restore_expected?) { false }
    assert_equal :missing, project.archive_availability_state

    project.archive_status_id = 1
    project.define_singleton_method(:filesystem_project_data_missing?) { true }
    project.define_singleton_method(:archive_restore_expected?) { true }
    assert_equal :archived, project.archive_availability_state

    project.archive_status_id = 3
    project.define_singleton_method(:filesystem_project_data_missing?) { false }
    project.define_singleton_method(:archive_restore_expected?) { false }
    assert_equal :archived, project.archive_availability_state

    project.archive_status_id = 4
    assert_equal :unarchiving, project.archive_availability_state
    assert project.being_unarchived?
    assert_not project.being_archived?

    project.archive_status_id = 2
    assert_equal :archiving, project.archive_availability_state
    assert project.being_archived?
    assert_not project.being_unarchived?
    assert_equal "archiving", project.unarchive_client_state
  end

  test "key must be unique" do
    key = "uniq#{SecureRandom.hex(3)}"
    create_test_project!(name: "First", key: key, user_id: 1)
    duplicate = Project.new(name: "Second", key: key, user_id: 1)

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:key], "has already been taken"
  end

  test "generate_unique_key returns an unused key" do
    taken_key = "taken#{SecureRandom.hex(3)}"
    create_test_project!(name: "Taken", key: taken_key, user_id: 1)

    key = Project.generate_unique_key

    assert_not Project.exists?(key: key)
    assert_equal 6, key.length
  end

  test "compliance_term_entries_for returns ontology identifiers for technology" do
    ott = OntologyTermType.find_by(name: "technology")
    skip "technology OntologyTermType with term and label paths is required" unless ott&.term_path.present? && ott.label_path.present?

    project = create_test_project!(name: "Tech ontology terms", key: "tot#{SecureRandom.hex(3)}")
    register_for_test_cleanup(
      Annot.create!(
        project_id: project.id,
        name: ott.label_path,
        latest_version: true,
        version_nber: 1,
        list_cat_json: ["raw_assay_label", "unknown"].to_json
      ),
      Annot.create!(
        project_id: project.id,
        name: ott.term_path,
        latest_version: true,
        version_nber: 1,
        list_cat_json: ["EFO:0030004", "unknown"].to_json
      )
    )

    entries = project.compliance_term_entries_for("technology")
    efo = entries.find { |entry| entry[:identifier] == "EFO:0030004" }
    unknown = entries.find { |entry| entry[:label].to_s.downcase == "unknown" && entry[:identifier].blank? }

    assert efo, "Expected an ontology term entry for EFO:0030004, got #{entries.inspect}"
    assert unknown, "Expected a non-ontology unknown entry, got #{entries.inspect}"

    cot = CellOntologyTerm.with_active_cell_ontology.find_by(identifier: "EFO:0030004", original: true)
    if cot&.name.present?
      assert_equal cot.name, efo[:label]
    else
      assert_equal "raw assay label", efo[:label]
    end

    expected_url = AsapData::OntologyIdentifierUrl.url_for("EFO:0030004")
    assert_equal expected_url, efo[:url]
    assert_match(%r{\Ahttps?://}, efo[:url].to_s)
  end

  test "compliance_term_entries_for uses projects.technology when ontology terms are missing" do
    project = create_test_project!(
      name: "Tech column fallback",
      key: "tcf#{SecureRandom.hex(3)}",
      technology: "10x 3' v3, Smart-seq2, Drop-seq"
    )

    entries = project.compliance_term_entries_for("technology")
    assert_equal ["10x 3' v3", "Smart-seq2", "Drop-seq"], entries.map { |entry| entry[:label] }
    assert entries.all? { |entry| entry[:identifier].blank? && entry[:url].blank? }
  end

  test "apply_project_type_from_assay_metadata assigns spat from visium annot when type is blank" do
    spat = ProjectType.find_by!(tag: "spat")
    project = create_test_project!(name: "Visium infer", key: "vis#{SecureRandom.hex(3)}", project_type_id: nil)
    register_for_test_cleanup(
      Annot.create!(
        project_id: project.id,
        name: "/col_attrs/assay_ontology_term_id",
        list_cat_json: ["EFO:0022857"].to_json,
        nber_cols: 10,
        dim: 1
      )
    )

    assert project.apply_project_type_from_assay_metadata!
    assert_equal spat.id, project.reload.project_type_id
  end

  test "apply_project_type_from_assay_metadata creates spat type when the row is missing" do
    ProjectType.find_by(tag: "spat")&.destroy!
    project = create_test_project!(name: "Visium create spat", key: "vcs#{SecureRandom.hex(3)}", project_type_id: nil)
    register_for_test_cleanup(
      Annot.create!(
        project_id: project.id,
        name: "/col_attrs/assay_ontology_term_id",
        list_cat_json: ["EFO:0022857"].to_json,
        nber_cols: 10,
        dim: 1
      )
    )

    assert project.apply_project_type_from_assay_metadata!
    spat = ProjectType.find_by!(tag: "spat")
    assert_equal spat.id, project.reload.project_type_id
  ensure
    ProjectType.ensure_for_tag!("spat")
  end

  test "apply_project_type_from_assay_metadata assigns atac from scATAC annot when type is blank" do
    atac = ProjectType.find_by!(tag: "atac")
    project = create_test_project!(name: "ATAC infer", key: "ata#{SecureRandom.hex(3)}", project_type_id: nil)
    register_for_test_cleanup(
      Annot.create!(
        project_id: project.id,
        name: "/col_attrs/assay_ontology_term_id",
        list_cat_json: ["EFO:0010891"].to_json,
        nber_cols: 10,
        dim: 1
      )
    )

    assert project.apply_project_type_from_assay_metadata!
    assert_equal atac.id, project.reload.project_type_id
  end

  test "apply_project_type_from_assay_metadata assigns multi from multiome annot when type is blank" do
    multi = ProjectType.find_by!(tag: "multi")
    project = create_test_project!(name: "Multiome infer", key: "mul#{SecureRandom.hex(3)}", project_type_id: nil)
    register_for_test_cleanup(
      Annot.create!(
        project_id: project.id,
        name: "/col_attrs/assay_ontology_term_id",
        list_cat_json: ["EFO:0030059"].to_json,
        nber_cols: 10,
        dim: 1
      )
    )

    assert project.apply_project_type_from_assay_metadata!
    assert_equal multi.id, project.reload.project_type_id
  end

  test "apply_project_type_from_assay_metadata does not override a set type" do
    sc = ProjectType.find_by!(tag: "sc")
    project = create_test_project!(name: "Keep sc", key: "ksc#{SecureRandom.hex(3)}", project_type_id: sc.id)
    register_for_test_cleanup(
      Annot.create!(
        project_id: project.id,
        name: "/col_attrs/assay_ontology_term_id",
        list_cat_json: ["EFO:0022857"].to_json,
        nber_cols: 10,
        dim: 1
      )
    )

    refute project.apply_project_type_from_assay_metadata!
    assert_equal sc.id, project.reload.project_type_id
  end

  test "apply_project_type_from_assay_metadata replaces sc default when requested" do
    sc = ProjectType.find_by!(tag: "sc")
    spat = ProjectType.find_by!(tag: "spat")
    project = create_test_project!(name: "Replace sc", key: "rsc#{SecureRandom.hex(3)}", project_type_id: sc.id)
    register_for_test_cleanup(
      Annot.create!(
        project_id: project.id,
        name: "/col_attrs/assay_ontology_term_id",
        list_cat_json: ["EFO:0022857"].to_json,
        nber_cols: 10,
        dim: 1
      )
    )

    assert project.apply_project_type_from_assay_metadata!(replace_sc_default: true)
    assert_equal spat.id, project.reload.project_type_id
  end

  test "inferred project type uses loom visium annot even when h5ad obs keys are also present" do
    project = create_test_project!(name: "Mixed format infer", key: "mix#{SecureRandom.hex(3)}", project_type_id: nil)
    register_for_test_cleanup(
      Annot.create!(
        project_id: project.id,
        name: "/col_attrs/assay_ontology_term_id",
        list_cat_json: ["EFO:0022857"].to_json,
        nber_cols: 10,
        dim: 1
      )
    )
    project.define_singleton_method(:cxg_validation_result) do
      { 'field_values' => { 'obs/assay_ontology_term_id' => ['EFO:0009899'] } }
    end

    assert_equal 'spat', project.inferred_project_type_tag_from_assay
  end
end
