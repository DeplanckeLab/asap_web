module ApplicationCable
  # Resolves who is on the other end of the socket so channels can authorize
  # subscriptions. Guests are allowed (sandbox projects, public projects); they
  # are identified by the sandbox key stored in their server-side session.
  #
  # The identity is captured once at connect time. Login is a full page load
  # (devise form uses turbo: false), which opens a new socket, so a signed-in
  # user never keeps a guest connection.
  class Connection < ActionCable::Connection::Base
    identified_by :current_user, :sandbox_key, :remote_ip

    def connect
      self.current_user = env['warden']&.user
      self.remote_ip = request.remote_ip
      self.sandbox_key = begin
        request.session[:sandbox].presence
      rescue StandardError => e
        Rails.logger.warn("[ActionCable] could not read session: #{e.class}: #{e.message}")
        nil
      end
    end
  end
end
