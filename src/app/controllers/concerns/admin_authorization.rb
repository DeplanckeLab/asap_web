require 'env_helpers'

module AdminAuthorization
  extend ActiveSupport::Concern

  def admin?
    user_email_in_list?('ADMIN_EMAILS')
  end

  def uab?
    admin? || user_email_in_list?('UAB_EMAILS')
  end

  def admin_report?
    user_email_in_list?('ADMIN_REPORT_EMAILS')
  end

  private

  def user_email_in_list?(key)
    user = Array(current_user).compact.first
    return false unless user.respond_to?(:email)

    EnvHelpers.email_in_list?(key, user.email)
  end

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
