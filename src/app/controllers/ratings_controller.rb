class RatingsController < ApplicationController
  before_action :authenticate_user!
  before_action :authorize_admin

  def index
    @ratings = Rating.includes(:user).order(created_at: :desc)
  end
end
