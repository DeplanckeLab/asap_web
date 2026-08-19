# frozen_string_literal: true

require_relative 'test_base_without_fixtures'
require 'fileutils'

class ProjectOwnershipTransferServiceTest < TestBaseWithoutFixtures
  setup do
    @tmp_root = Dir.mktmpdir('project-ownership-transfer')
    @previous_user_data_dir = ENV['USER_DATA_DIR']
    ENV['USER_DATA_DIR'] = File.join(@tmp_root, 'projects')
    FileUtils.mkdir_p(ENV['USER_DATA_DIR'])

    @owner = register_for_test_cleanup(
      User.create!(email: "own_xfer_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )
    @new_owner = register_for_test_cleanup(
      User.create!(email: "new_xfer_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )
    @other = register_for_test_cleanup(
      User.create!(email: "oth_xfer_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )
    @project = create_test_project!(
      name: 'Ownership transfer',
      key: "otx#{SecureRandom.hex(3)}",
      user_id: @owner.id
    )
  end

  teardown do
    destroy_registered_test_records!
    ENV['USER_DATA_DIR'] = @previous_user_data_dir
    FileUtils.rm_rf(@tmp_root) if @tmp_root.present?
  end

  test 'transfers project ownership and moves the project directory' do
    project_dir = @project.data_dir
    FileUtils.mkdir_p(project_dir)
    File.write(project_dir + 'input_file', 'data')
    archive_file = Pathname.new("#{project_dir}.tgz")
    File.write(archive_file, 'tgz')

    result = ProjectOwnershipTransferService.call!(
      project: @project,
      new_owner_email: @new_owner.email.upcase,
      transfer: {}
    )

    @project.reload
    assert_equal @new_owner.id, @project.user_id
    assert_equal [@new_owner], [result[:new_owner]]
    assert_empty result[:transferred]

    new_dir = Pathname.new(ENV['USER_DATA_DIR']) + @new_owner.id.to_s + @project.key
    assert File.directory?(new_dir.to_s)
    assert_equal 'data', File.read(new_dir + 'input_file')
    assert File.exist?("#{new_dir}.tgz")
    refute File.exist?(project_dir.to_s)
    refute @project.shares.where(user_id: @owner.id).exists?
  end

  test 'reassigns selected related records owned by the previous owner' do
    step = Step.first
    skip 'No Step available' unless step

    owner_run = register_for_test_cleanup(
      Run.create!(project_id: @project.id, user_id: @owner.id, step_id: step.id, status_id: 1, num: 1)
    )
    other_run = register_for_test_cleanup(
      Run.create!(project_id: @project.id, user_id: @other.id, step_id: step.id, status_id: 1, num: 2)
    )
    owner_annot = register_for_test_cleanup(
      Annot.create!(project_id: @project.id, user_id: @owner.id, name: '/col_attrs/owner_meta', dim: 1)
    )

    pcs = register_for_test_cleanup(ProjectCellSet.create!(key: "pcs#{SecureRandom.hex(4)}"))
    cell_set = register_for_test_cleanup(
      CellSet.create!(project_cell_set_id: pcs.id, key: SecureRandom.hex(8), nber_cells: 1)
    )
    cla = register_for_test_cleanup(
      Cla.create!(project_id: @project.id, cell_set_id: cell_set.id, user_id: @owner.id, cat: 'c1')
    )
    owner_vote = register_for_test_cleanup(
      ClaVote.create!(cla_id: cla.id, user_id: @owner.id, agree: true)
    )
    other_vote = register_for_test_cleanup(
      ClaVote.create!(cla_id: cla.id, user_id: @other.id, agree: false)
    )

    owner_selection = register_for_test_cleanup(
      ProjectOwnershipTransferService::SelectionRecord.create!(project_id: @project.id, user_id: @owner.id, label: 'sel-owner')
    )
    other_selection = register_for_test_cleanup(
      ProjectOwnershipTransferService::SelectionRecord.create!(project_id: @project.id, user_id: @other.id, label: 'sel-other')
    )

    ProjectOwnershipTransferService.call!(
      project: @project,
      new_owner_email: @new_owner.email,
      transfer: {
        runs: true,
        selections: true,
        clas: true,
        cla_votes: true,
        annots: true
      }
    )

    assert_equal @new_owner.id, owner_run.reload.user_id
    assert_equal @other.id, other_run.reload.user_id
    assert_equal @new_owner.id, owner_annot.reload.user_id
    assert_equal @new_owner.id, cla.reload.user_id
    assert_equal @new_owner.id, owner_vote.reload.user_id
    assert_equal @other.id, other_vote.reload.user_id
    assert_equal @new_owner.id, owner_selection.reload.user_id
    assert_equal @other.id, other_selection.reload.user_id
  end

  test 'transfer_all reassigns owned records even when transfer options are omitted' do
    step = Step.first
    skip 'No Step available' unless step

    run = register_for_test_cleanup(
      Run.create!(project_id: @project.id, user_id: @owner.id, step_id: step.id, status_id: 1, num: 1)
    )

    ProjectOwnershipTransferService.call!(
      project: @project,
      new_owner_email: @new_owner.email,
      transfer_all: true
    )

    assert_equal @new_owner.id, run.reload.user_id
    refute @project.shares.where(user_id: @owner.id).exists?
  end

  test 'does not reassign runs when the option is off' do
    step = Step.first
    skip 'No Step available' unless step

    run = register_for_test_cleanup(
      Run.create!(project_id: @project.id, user_id: @owner.id, step_id: step.id, status_id: 1, num: 1)
    )

    ProjectOwnershipTransferService.call!(
      project: @project,
      new_owner_email: @new_owner.email,
      transfer: { runs: false }
    )

    assert_equal @owner.id, run.reload.user_id
    assert_equal @new_owner.id, @project.reload.user_id

    share = @project.shares.find_by(user_id: @owner.id)
    assert share
    assert share.view_perm?
    assert share.analyze_perm?
  end

  test 'does not share the previous owner when they no longer own records' do
    step = Step.first
    skip 'No Step available' unless step

    run = register_for_test_cleanup(
      Run.create!(project_id: @project.id, user_id: @owner.id, step_id: step.id, status_id: 1, num: 1)
    )

    ProjectOwnershipTransferService.call!(
      project: @project,
      new_owner_email: @new_owner.email,
      transfer: { runs: true }
    )

    assert_equal @new_owner.id, run.reload.user_id
    refute @project.shares.where(user_id: @owner.id).exists?
  end

  test 'collaborative_annotations transfers both annotations and votes' do
    pcs = register_for_test_cleanup(ProjectCellSet.create!(key: "pcs#{SecureRandom.hex(4)}"))
    cell_set = register_for_test_cleanup(
      CellSet.create!(project_cell_set_id: pcs.id, key: SecureRandom.hex(8), nber_cells: 1)
    )
    annotation = register_for_test_cleanup(
      Cla.create!(project_id: @project.id, cell_set_id: cell_set.id, user_id: @owner.id, cat: 'c1')
    )
    vote = register_for_test_cleanup(
      ClaVote.create!(cla_id: annotation.id, user_id: @owner.id, agree: true)
    )

    result = ProjectOwnershipTransferService.call!(
      project: @project,
      new_owner_email: @new_owner.email,
      transfer: { collaborative_annotations: true }
    )

    assert_equal @new_owner.id, annotation.reload.user_id
    assert_equal @new_owner.id, vote.reload.user_id
    assert_includes result[:transferred], :clas
    assert_includes result[:transferred], :cla_votes
  end

  test 'skips a collaborative annotation vote when the new owner already voted' do
    pcs = register_for_test_cleanup(ProjectCellSet.create!(key: "pcs#{SecureRandom.hex(4)}"))
    cell_set = register_for_test_cleanup(
      CellSet.create!(project_cell_set_id: pcs.id, key: SecureRandom.hex(8), nber_cells: 1)
    )
    cla = register_for_test_cleanup(
      Cla.create!(project_id: @project.id, cell_set_id: cell_set.id, user_id: @owner.id, cat: 'c1')
    )
    owner_vote = register_for_test_cleanup(
      ClaVote.create!(cla_id: cla.id, user_id: @owner.id, agree: true)
    )
    new_owner_vote = register_for_test_cleanup(
      ClaVote.create!(cla_id: cla.id, user_id: @new_owner.id, agree: false)
    )

    ProjectOwnershipTransferService.call!(
      project: @project,
      new_owner_email: @new_owner.email,
      transfer: { cla_votes: true }
    )

    assert_equal @owner.id, owner_vote.reload.user_id
    assert_equal @new_owner.id, new_owner_vote.reload.user_id
  end

  test 'removes an existing share for the new owner' do
    share = register_for_test_cleanup(
      Share.create!(project_id: @project.id, user_id: @new_owner.id, email: @new_owner.email, view_perm: true)
    )

    ProjectOwnershipTransferService.call!(
      project: @project,
      new_owner_email: @new_owner.email
    )

    refute Share.exists?(share.id)
  end

  test 'raises when the email does not match an existing user' do
    error = assert_raises(ProjectOwnershipTransferService::Error) do
      ProjectOwnershipTransferService.call!(
        project: @project,
        new_owner_email: 'missing-user@example.com'
      )
    end
    assert_match(/No user account exists/, error.message)
    assert_equal @owner.id, @project.reload.user_id
  end

  test 'raises when transferring to the current owner' do
    error = assert_raises(ProjectOwnershipTransferService::Error) do
      ProjectOwnershipTransferService.call!(
        project: @project,
        new_owner_email: @owner.email
      )
    end
    assert_match(/already owns/, error.message)
  end

  test 'raises for sandbox projects' do
    @project.update!(sandbox: true)
    error = assert_raises(ProjectOwnershipTransferService::Error) do
      ProjectOwnershipTransferService.call!(
        project: @project,
        new_owner_email: @new_owner.email
      )
    end
    assert_match(/Sandbox/, error.message)
  end
end
