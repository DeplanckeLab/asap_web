class DockerImagesController < ApplicationController
  before_action :set_docker_image, only: [:show, :edit, :update, :destroy]
  before_action :ensure_admin!, except: [:index, :show]

  def index
    @docker_images = DockerImage.order(created_at: :desc)
  end

  def show; end

  def new
    @docker_image = DockerImage.new
  end

  def edit; end

  def create
    @docker_image = DockerImage.new(docker_image_params)
    if @docker_image.save
      redirect_to @docker_image, notice: 'Docker image was successfully created.'
    else
      render :new, status: :unprocessable_entity
    end
  end

  def update
    if @docker_image.update(docker_image_params)
      redirect_to @docker_image, notice: 'Docker image was successfully updated.'
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @docker_image.destroy
    redirect_to docker_images_url, notice: 'Docker image was successfully destroyed.'
  end

  private

  def set_docker_image
    @docker_image = DockerImage.find(params[:id])
  end

  def ensure_admin!
    return if admin?

    redirect_to docker_images_path, alert: 'You are not authorized to perform this action.'
  end

  def docker_image_params
    params.require(:docker_image).permit(
      :name,
      :tag,
      :description,
      :tools_json,
      :tool_versions_json,
      :metadata_json
    )
  end
end

