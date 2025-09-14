class RunsController < ApplicationController
  before_action :set_run, only: [:show, :edit, :update, :destroy]

  # GET /runs
  def index
    @runs = Run.all
  end

  # GET /runs/1
  def show
  end

  # GET /runs/new
  def new
    @run = Run.new
  end

  # GET /runs/1/edit
  def edit
  end

  # POST /runs
  def create
    @run = Run.new(run_params)

    if @run.save
      redirect_to @run, notice: 'Run was successfully created.'
    else
      render :new
    end
  end

  # PATCH/PUT /runs/1
  def update
    if @run.update(run_params)
      redirect_to @run, notice: 'Run was successfully updated.'
    else
      render :edit
    end
  end

  # DELETE /runs/1
  def destroy
    @run.destroy
    head :no_content
  end

  private

  def set_run
    @run = Run.find(params[:id])
  end

  def run_params
    params.fetch(:run, {})
  end
end

