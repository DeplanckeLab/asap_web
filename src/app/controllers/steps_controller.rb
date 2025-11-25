class StepsController < ApplicationController
  before_action :set_step, only: [:show, :edit, :update, :destroy]
  before_action :ensure_admin!, except: [:index, :show]

  def index
    @docker_images = DockerImage.order(:name)
    @latest_docker_image_id = DockerImage.order(id: :desc).limit(1).pluck(:id).first
    @selected_docker_image_id =
      if params.key?(:docker_image_id)
        params[:docker_image_id].presence
      else
        @latest_docker_image_id&.to_s
      end

    @steps = Step.includes(:docker_image).order(:rank, :name)
    @steps = @steps.where(docker_image_id: @selected_docker_image_id) if @selected_docker_image_id.present?
  end

  def show
  end

  def new
    @step = Step.new
  end

  def edit
  end

  def create
    @step = Step.new(step_params)
    if @step.save
      redirect_to @step, notice: 'Step was successfully created.'
    else
      render :new, status: :unprocessable_entity
    end
  end

  def update
    if @step.update(step_params)
      redirect_to @step, notice: 'Step was successfully updated.'
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @step.destroy
    redirect_to steps_url, notice: 'Step was successfully destroyed.'
  end

  private

  def set_step
    @step = Step.find(params[:id])
  end

  def ensure_admin!
    return if admin?

    redirect_to steps_path, alert: 'You are not authorized to perform this action.'
  end

  def step_params
    params.require(:step).permit(
      :obj_name, :name, :label, :tag, :description, :warnings, :rank,
      :multiple_runs, :attrs_json, :method_attrs_json, :output_json,
      :command_json, :has_std_dashboard, :has_std_view, :has_std_form,
      :dashboard_card_json, :show_view_json, :hidden, :group_name, :version_id, :docker_image_id
    )
  end
end

