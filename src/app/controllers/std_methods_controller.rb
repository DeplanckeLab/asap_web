class StdMethodsController < ApplicationController
  before_action :set_std_method, only: [:show, :edit, :update, :destroy]
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

    @std_methods = StdMethod.includes(:step, :docker_image).order(:name)
    @std_methods = @std_methods.where(docker_image_id: @selected_docker_image_id) if @selected_docker_image_id.present?
  end

  def show
  end

  def new
    @std_method = StdMethod.new
    @std_method.version_id = params[:version_id] if params[:version_id].present?
  end

  def edit
  end

  def create
    @std_method = StdMethod.new(std_method_params)
    @std_method.docker_image_id = @std_method.step.docker_image_id if @std_method.step&.docker_image_id.present?

    if @std_method.save
      redirect_to @std_method, notice: 'Standard method was successfully created.'
    else
      render :new, status: :unprocessable_entity
    end
  end

  def update
    if @std_method.update(std_method_params)
      redirect_to @std_method, notice: 'Standard method was successfully updated.'
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @std_method.destroy
    redirect_to std_methods_url, notice: 'Standard method was successfully destroyed.'
  end

  private

  def set_std_method
    @std_method = StdMethod.find(params[:id])
  end

  def ensure_admin!
    return if admin?

    redirect_to std_methods_path, alert: 'You are not authorized to perform this action.'
  end

  def std_method_params
    params.require(:std_method).permit(
      :name, :label, :step_id, :description, :short_label, :program, :command_json, :nber_cores,
      :link, :speed_id, :attrs_json, :attr_layout_json, :obj_attrs_json, :obsolete, :version_id, :docker_image_id
    )
  end
end

