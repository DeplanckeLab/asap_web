# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class CloneRelatedProjectsQueryTest < TestBaseWithoutFixtures
  setup do
    @user = register_for_test_cleanup(User.create!(email: "clone_rel_#{SecureRandom.hex(4)}@example.com", password: 'password123'))
    @other = register_for_test_cleanup(User.create!(email: "clone_rel_o_#{SecureRandom.hex(4)}@example.com", password: 'password123'))
    @root = create_test_project!(name: 'Root', key: "root#{SecureRandom.hex(3)}", user_id: @user.id)
    @child_mine = create_test_project!(
      name: 'My child',
      key: "mych#{SecureRandom.hex(3)}",
      user_id: @user.id,
      cloned_project_id: @root.id,
      root_project_id: @root.id
    )
    @child_other = create_test_project!(
      name: 'Other child',
      key: "othc#{SecureRandom.hex(3)}",
      user_id: @other.id,
      cloned_project_id: @root.id,
      root_project_id: @root.id
    )
    @readable_if = ->(_project) { true }
  end

  test 'current scope returns only the project' do
    result = CloneRelatedProjectsQuery.call(project: @root, scope: 'current', user: @user, readable_if: @readable_if)
    assert result[:ok]
    assert_equal [@root.id], result[:projects].map { |row| row[:id] }
  end

  test 'my_clones returns current plus direct children owned by user' do
    result = CloneRelatedProjectsQuery.call(project: @root, scope: 'my_clones', user: @user, readable_if: @readable_if)
    assert result[:ok]
    assert_equal [@root.id, @child_mine.id].sort, result[:projects].map { |row| row[:id] }.sort
  end

  test 'all_children returns current plus every direct child' do
    result = CloneRelatedProjectsQuery.call(project: @root, scope: 'all_children', user: @user, readable_if: @readable_if)
    assert result[:ok]
    assert_equal [@root.id, @child_mine.id, @child_other.id].sort, result[:projects].map { |row| row[:id] }.sort
  end

  test 'lineage returns root and all clones sharing root_project_id' do
    result = CloneRelatedProjectsQuery.call(project: @child_mine, scope: 'lineage', user: @user, readable_if: @readable_if)
    assert result[:ok]
    assert_equal [@root.id, @child_mine.id, @child_other.id].sort, result[:projects].map { |row| row[:id] }.sort
  end

  test 'filters unreadables' do
    readable_if = ->(project) { project.id != @child_other.id }
    result = CloneRelatedProjectsQuery.call(project: @root, scope: 'all_children', user: @user, readable_if: readable_if)
    assert result[:ok]
    assert_equal [@root.id, @child_mine.id].sort, result[:projects].map { |row| row[:id] }.sort
  end
end
