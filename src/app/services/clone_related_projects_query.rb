# frozen_string_literal: true

# Lists projects related to +project+ by clone scope for the annotations page.
#
# Scopes:
# - current: the project itself
# - my_clones: direct children owned by +user+
# - all_children: all direct children
# - lineage: root + every project sharing root_project_id
class CloneRelatedProjectsQuery
  SCOPES = %w[current my_clones all_children lineage].freeze

  class << self
    def call(project:, scope:, user:, readable_if:)
      new(project: project, scope: scope, user: user, readable_if: readable_if).call
    end
  end

  def initialize(project:, scope:, user:, readable_if:)
    @project = project
    @scope = scope.to_s
    @user = user
    @readable_if = readable_if
  end

  def call
    return error("Unknown scope.") unless SCOPES.include?(@scope)
    return error("Project is required.") unless @project
    return error("readable_if callable is required.") unless @readable_if.respond_to?(:call)

    projects = scoped_projects
    projects = projects.select { |project| @readable_if.call(project) }
    {
      ok: true,
      scope: @scope,
      projects: projects.map { |project| serialize(project) }
    }
  end

  private

  def error(message)
    { ok: false, error: message, projects: [] }
  end

  def scoped_projects
    case @scope
    when 'current'
      [@project]
    when 'my_clones'
      return [@project] unless @user

      children = Project.where(cloned_project_id: @project.id, user_id: @user.id).order(:id).to_a
      ([@project] + children).uniq(&:id)
    when 'all_children'
      children = Project.where(cloned_project_id: @project.id).order(:id).to_a
      ([@project] + children).uniq(&:id)
    when 'lineage'
      lineage_projects
    else
      []
    end
  end

  def lineage_projects
    root_id = @project.root_project_id.presence || @project.id
    root = Project.find_by(id: root_id)
    clones = Project.where(root_project_id: root_id).order(:id).to_a
    rows = []
    rows << root if root
    rows.concat(clones)
    rows.uniq(&:id)
  end

  def serialize(project)
    {
      id: project.id,
      key: project.key.to_s,
      name: project.name.to_s.presence || project.key.to_s,
      public_id: project.public_id,
      is_current: project.id == @project.id
    }
  end
end
