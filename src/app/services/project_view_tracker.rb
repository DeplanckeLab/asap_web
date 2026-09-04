# frozen_string_literal: true

require 'digest'

class ProjectViewTracker
  # Guest tokens are hashed so a long/odd session id can never overflow
  # project_view_logs.viewer_token (varchar 128) and 500 the project page.
  GUEST_TOKEN_PREFIX = 's:'
  USER_TOKEN_PREFIX = 'u:'

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
    return "#{USER_TOKEN_PREFIX}#{current_user.id}" if current_user

    sid = normalize_session_id(session_id)
    raise ArgumentError, 'session_id is required for guest view tracking' if sid.blank?

    "#{GUEST_TOKEN_PREFIX}#{Digest::SHA256.hexdigest(sid)}"
  end

  def self.normalize_session_id(session_id)
    if session_id.respond_to?(:public_id)
      public_id = session_id.public_id
      return public_id.to_s if public_id.present?
    end

    session_id.to_s
  end
  private_class_method :normalize_session_id
end
