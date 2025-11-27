class FuChannel < ApplicationCable::Channel
  def subscribed
    fu_id = params[:fu_id]
    fu_id.present? ? stream_from("fu_#{fu_id}") : reject
  end

  def unsubscribed
    # Cleanup is handled automatically by ActionCable streams.
  end
end

