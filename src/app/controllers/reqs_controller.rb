class ReqsController < ApplicationController
  before_action :set_req, only: [:show, :edit, :update, :destroy]

  # GET /reqs
  def index
    @reqs = Req.all
  end

  # GET /reqs/1
  def show
  end

  # GET /reqs/new
  def new
    @req = Req.new
  end

  # GET /reqs/1/edit
  def edit
  end

  # POST /reqs
  def create
    @req = Req.new(req_params)

    if @req.save
      redirect_to @req, notice: 'Req was successfully created.'
    else
      render :new
    end
  end

  # PATCH/PUT /reqs/1
  def update
    if @req.update(req_params)
      redirect_to @req, notice: 'Req was successfully updated.'
    else
      render :edit
    end
  end

  # DELETE /reqs/1
  def destroy
    @req.destroy
    head :no_content
  end

  private

  def set_req
    @req = Req.find(params[:id])
  end

  def req_params
    params.fetch(:req, {})
  end
end

