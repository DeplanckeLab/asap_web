class ExpEntriesController < ApplicationController
  before_action :set_exp_entry, only: [:show, :summary]

  # GET /exp_entries/1
  def show
    respond_to do |format|
      format.html
      format.json { render json: @exp_entry }
    end
  end

  # GET /exp_entries/1/summary
  def summary
    respond_to do |format|
      format.html { render layout: false }
      format.json { render json: @exp_entry }
    end
  end

  private

  def set_exp_entry
    @exp_entry = ExpEntry.find(params[:id])
  end
end

