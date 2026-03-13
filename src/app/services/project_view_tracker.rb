class ProjectViewTracker
  def self.track!(project:, current_user:, session_id:, viewed_at: Time.current)
    viewer_token = build_viewer_token(current_user: current_user, session_id: session_id)
    viewed_on = viewed_at.to_date

    result = ProjectViewLog.insert_all(
      [
        {
          project_id: project.id,
          viewer_token: viewer_token,
          viewed_on: viewed_on,
          created_at: viewed_at,
          updated_at: viewed_at
        }
      ],
      unique_by: :idx_pvl_on_project_viewer_day,
      returning: %w[id]
    )

    if result.rows.any?
      Project.where(id: project.id).update_all(["viewed_at = ?, nber_views = COALESCE(nber_views, 0) + 1", viewed_at]) 
    else
      Project.where(id: project.id).update_all(viewed_at: viewed_at)
    end
  end

  def self.build_viewer_token(current_user:, session_id:)
    return "u:#{current_user.id}" if current_user

    sid = session_id.to_s
    raise ArgumentError, 'session_id is required for guest view tracking' if sid.blank?

    "s:#{sid}"
  end
end
