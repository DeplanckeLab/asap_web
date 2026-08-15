# frozen_string_literal: true

class StorageUsagesController < ApplicationController
  before_action :authenticate_user!
  before_action :authorize_admin

  def index
    refresh = ActiveModel::Type::Boolean.new.cast(params[:refresh])
    @report = StorageUsageReport.call(refresh: refresh)
  end
end
