class ApplicationController < ActionController::Base
  include AdminAuthorization
  include ProjectAuthorization
  
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Skip authentication for certain actions that can be accessed publicly
  # Authentication will be checked at the action level via readable?/exportable? methods
  skip_before_action :authenticate_user!, only: [:index, :show, :metadata_coordinates, :metadata_vectors, :gene_expression, :get_file], raise: false
  before_action :configure_permitted_parameters, if: :devise_controller?
  
  # Initialize session for sandbox projects
  before_action :init_session

  # Make authorization methods available to views
  helper_method :admin?, :readable?, :exportable?, :exportable_item?, :editable?, :owner?, :read_only?, :clonable?

  protected

  def configure_permitted_parameters
    devise_parameter_sanitizer.permit(:sign_up, keys: [:displayed_name])
    devise_parameter_sanitizer.permit(:account_update, keys: [:displayed_name])
  end

  # Initialize session for sandbox projects
  def init_session
    session[:sandbox] ||= create_sandbox_key
  end

  # Generate a random key for sandbox sessions
  def create_sandbox_key
    Array.new(6) { [*'0'..'9', *'a'..'z'].sample }.join
  end

end

