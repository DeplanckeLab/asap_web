module AdminAuthorization
  extend ActiveSupport::Concern

  def admin?
    # Return false if no authentication system is in place
    return false unless current_user
    
    admin_emails =
      if defined?(APP_CONFIG) && APP_CONFIG[:admin_emails]
        Array(APP_CONFIG[:admin_emails])
      else
        ENV['ADMIN_EMAILS']&.split(',') || []
      end
    admin_emails.include?(current_user.email)
  end

  private

  def authorize_admin
    unless admin?
      redirect_to root_path, alert: 'Access denied'
    end
  end
end 