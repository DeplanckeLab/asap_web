module AdminAuthorization
  extend ActiveSupport::Concern

  def admin?
    # Return false if no authentication system is in place
    return false unless current_user
    
    # Check if current user's email is in admin emails list
    admin_emails = ENV['ADMIN_EMAILS']&.split(',') || []
    admin_emails.include?(current_user.email)
  end

  private

  def authorize_admin
    unless admin?
      redirect_to root_path, alert: 'Access denied'
    end
  end
end 