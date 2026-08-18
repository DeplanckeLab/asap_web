class EnsureCanonicalProjectTypes < ActiveRecord::Migration[8.0]
  def up
    return unless table_exists?(:project_types)

    ProjectType::CANONICAL.each_key do |tag|
      ProjectType.ensure_for_tag!(tag)
    end
  end

  def down
    # Keep canonical project types; they may already be assigned to projects.
  end
end
