require 'env_helpers'

module AdminAuthorization
  extend ActiveSupport::Concern

  def admin?
    user = Array(current_user).compact.first
    return false unless user.respond_to?(:email)

    EnvHelpers.email_list('ADMIN_EMAILS').include?(user.email)
  end

  private

  def authorize_admin
    unless admin?
      redirect_to unauthorized_path
    end
  end
end 