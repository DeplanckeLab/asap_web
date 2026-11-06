module ApplicationCable
  class Channel < ActionCable::Channel::Base
    # Reuse the controller authorization rules (readable?, editable?, admin?, ...)
    # with a channel-side view of current_user / session / request.
    include AdminAuthorization
    include ProjectAuthorization

    AuthRequest = Struct.new(:remote_ip)

    private

    def session
      @auth_session ||= ActiveSupport::HashWithIndifferentAccess.new(sandbox: connection.sandbox_key)
    end

    def request
      @auth_request ||= AuthRequest.new(connection.remote_ip)
    end

    def user_signed_in?
      current_user.present?
    end
  end
end
