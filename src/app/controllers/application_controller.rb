class ApplicationController < ActionController::Base
  include AdminAuthorization
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Devise authentication
  before_action :authenticate_user!, except: [:index, :show]
  before_action :configure_permitted_parameters, if: :devise_controller?

  # Make admin? method available to views
  helper_method :admin?

  protected

  def configure_permitted_parameters
    devise_parameter_sanitizer.permit(:sign_up, keys: [:displayed_name])
    devise_parameter_sanitizer.permit(:account_update, keys: [:displayed_name])
  end
end

