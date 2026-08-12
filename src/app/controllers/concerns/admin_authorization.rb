require 'env_helpers'

module AdminAuthorization
  extend ActiveSupport::Concern

  def admin?
    user = Array(current_user).compact.first
    return false unless user.respond_to?(:email)
    email = user.email.to_s.strip.downcase
    return false if email.empty?

    EnvHelpers.email_list('ADMIN_EMAILS')
      .map { |value| value.to_s.strip.downcase }
      .include?(email)
  end

  def uab?
    return true if admin?

    user = Array(current_user).compact.first
    return false unless user.respond_to?(:email)
    email = user.email.to_s.strip.downcase
    return false if email.empty?

    EnvHelpers.email_list('UAB_EMAILS')
      .map { |value| value.to_s.strip.downcase }
      .include?(email)
  end

  private

  def authorize_admin
    unless admin?
      redirect_to unauthorized_path
    end
  end

  def authorize_uab
    unless uab?
      redirect_to unauthorized_path
    end
  end
end
