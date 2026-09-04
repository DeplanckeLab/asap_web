# frozen_string_literal: true

class ServerErrorsController < ApplicationController
  PER_PAGE = 25

  before_action :authenticate_user!
  before_action :authorize_admin
  before_action :set_server_error, only: :show

  def index
    @page = [params[:page].to_i, 1].max
    @per_page = PER_PAGE

    scope = ServerError.includes(:user).recent
    @total_count = scope.count
    total_pages = [(@total_count.to_f / @per_page).ceil, 1].max
    @page = [@page, total_pages].min
    @server_errors = scope.offset((@page - 1) * @per_page).limit(@per_page)
  end

  def show
  end

  private

  def set_server_error
    @server_error = ServerError.find(params[:id])
  end
end
