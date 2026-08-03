# frozen_string_literal: true

require 'minitest/mock'
require_relative 'test_base_without_fixtures'

class ConsensusAnnotationPreviewServiceTest < TestBaseWithoutFixtures
  setup do
    @tmp_root = Dir.mktmpdir('consensus-preview')
    @previous_user_data_dir = ENV['USER_DATA_DIR']
    ENV['USER_DATA_DIR'] = File.join(@tmp_root, 'projects')
    FileUtils.mkdir_p(ENV['USER_DATA_DIR'])

    @user = register_for_test_cleanup(User.create!(email: "prev_#{SecureRandom.hex(4)}@example.com", password: 'password123'))
    @project = create_test_project!(name: 'Preview project', key: "prv#{SecureRandom.hex(3)}", user_id: @user.id)
    @project_b = create_test_project!(
      name: 'Preview clone',
      key: "prb#{SecureRandom.hex(3)}",
      user_id: @user.id,
      cloned_project_id: @project.id,
      root_project_id: @project.id
    )

    project_dir = Pathname.new(ENV['USER_DATA_DIR']) + @user.id.to_s + @project.key
    FileUtils.mkdir_p(project_dir)
    @loom_file = 'main.loom'
    File.write(project_dir + @loom_file, 'loom-stub')

    @pcs = register_for_test_cleanup(ProjectCellSet.create!(key: "pcs#{SecureRandom.hex(4)}"))
    @small_set = register_for_test_cleanup(CellSet.create!(project_cell_set_id: @pcs.id, key: SecureRandom.hex(8), nber_cells: 2))
    @large_set = register_for_test_cleanup(CellSet.create!(project_cell_set_id: @pcs.id, key: SecureRandom.hex(8), nber_cells: 4))
    @ott = OntologyTermType.find_by(name: 'cell_type') ||
           register_for_test_cleanup(OntologyTermType.create!(name: 'cell_type', label: 'Cell type'))

    @cla_small = register_for_test_cleanup(
      Cla.create!(
        project_id: @project.id,
        cell_set_id: @small_set.id,
        ontology_term_type_id: @ott.id,
        name: 'Alpha',
        cat: 'A',
        nber_agree: 5,
        nber_disagree: 0,
        user_id: @user.id
      )
    )
    @cla_large = register_for_test_cleanup(
      Cla.create!(
        project_id: @project_b.id,
        cell_set_id: @large_set.id,
        ontology_term_type_id: @ott.id,
        name: 'Beta',
        cat: 'B',
        nber_agree: 2,
        nber_disagree: 0,
        user_id: @user.id
      )
    )
    @cla_tie_a = register_for_test_cleanup(
      Cla.create!(
        project_id: @project.id,
        cell_set_id: @small_set.id,
        ontology_term_type_id: @ott.id,
        name: 'Gamma',
        cat: 'G',
        nber_agree: 5,
        nber_disagree: 0,
        user_id: @user.id
      )
    )
  end

  teardown do
    destroy_registered_test_records!
    ENV['USER_DATA_DIR'] = @previous_user_data_dir
    FileUtils.rm_rf(@tmp_root) if @tmp_root.present?
  end

  test 'detects equal-rank annotations on the same cell set' do
    result = preview_call(
      indices_by_cell_set_id: { @small_set.id => [0, 1], @large_set.id => [0, 1, 2, 3] },
      build_vectors: false
    )
    assert result[:ok], result[:error]
    assert result[:equal_rank].any? { |row| row[:cell_set_id] == @small_set.id }
    assert_operator result[:unresolved_equal_rank_count], :>=, 1
  end

  test 'detects cell-set collisions with preferred first-write winner' do
    @cla_tie_a.update!(obsolete: true)

    result = preview_call(
      indices_by_cell_set_id: { @small_set.id => [0, 1], @large_set.id => [1, 2, 3] },
      build_vectors: false
    )
    assert result[:ok], result[:error]
    assert_operator result[:collision_count], :>=, 1
    collision = result[:collisions].find { |row| row[:alternative_cell_set_id] == @large_set.id }
    assert collision
    assert_equal @small_set.id, collision[:preferred_cell_set_id]
    assert_equal 'Alpha', collision[:preferred][:label]
    assert_equal 'Beta', collision[:alternative][:label]
    assert collision.key?(:affects)
  end

  test 'build_vectors requires equal-rank resolution' do
    result = preview_call(
      indices_by_cell_set_id: { @small_set.id => [0, 1], @large_set.id => [2, 3] },
      build_vectors: true
    )
    assert_equal false, result[:ok]
    assert_match(/equal-rank/i, result[:error])
  end

  test 'build_vectors succeeds after equal-rank choice' do
    result = preview_call(
      indices_by_cell_set_id: { @small_set.id => [0, 1], @large_set.id => [2, 3] },
      equal_rank_choices: { @small_set.id.to_s => @cla_small.id },
      build_vectors: true
    )
    assert result[:ok], result[:error]
    assert_equal 4, result[:assigned_cell_count]
    assert_equal 'Alpha', result[:labels][0]
    assert_equal 'Beta', result[:labels][2]
  end

  private

  def preview_call(indices_by_cell_set_id:, build_vectors:, equal_rank_choices: {}, collision_choices: {})
    service = ConsensusAnnotationPreviewService.new(
      project: @project,
      ontology_term_type_id: @ott.id,
      project_ids: [@project.id, @project_b.id],
      readable_if: ->(_p) { true },
      equal_rank_choices: equal_rank_choices,
      collision_choices: collision_choices,
      build_vectors: build_vectors
    )
    service.define_singleton_method(:ensure_current_annot_cell_sets!) { |_loom| nil }
    service.define_singleton_method(:first_non_empty_vector) { |_path, _paths| %w[c0 c1 c2 c3] }
    service.define_singleton_method(:cell_indices_for) do |cell_set, *_|
      indices_by_cell_set_id[cell_set.id] || []
    end

    Annot.stub(:available_loom_files, ->(_project_id) { [@loom_file] }) do
      service.call
    end
  end
end
