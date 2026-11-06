class FuChannel < ApplicationCable::Channel
  def subscribed
    fu = Fu.find_by(id: params[:fu_id]) if params[:fu_id].present?
    fu && fu_accessible?(fu) ? stream_from("fu_#{fu.id}") : reject
  end

  def unsubscribed
    # Cleanup is handled automatically by ActionCable streams.
  end

  private

  # Mirrors FusController#find_fu_for_current_actor.
  def fu_accessible?(fu)
    return true if admin?

    project = fu.project
    if current_user
      return true if fu.user_id == current_user.id
      return true if project && project.user_id == current_user.id
    elsif fu.user_id.nil? && session[:sandbox].present? && fu.project_key == session[:sandbox]
      return true
    end

    project.present? && editable?(project)
  end
end
