module AdminAuthorization
  extend ActiveSupport::Concern

  private

  def admin?
    ENV['ADMIN_EMAILS'].split(',').include? current_user&.email
  end

  def authorize_admin
    unless admin?
      redirect_to root_path, alert: 'Access denied'
    end
  end
end 