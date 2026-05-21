class StdMethodsController < ApplicationController
  before_action :set_std_method, only: [:show, :edit, :update, :destroy]
  before_action :ensure_admin!, except: [:index, :show]

  def index
    @versions = Version.where('id > 3').order(id: :desc)
    @versions = @versions.where(activated: true) unless admin?
    @latest_version_id = @versions.maximum(:id)

    @selected_version_id =
      if params.key?(:version_id)
        params[:version_id].presence&.to_s
      else
        @latest_version_id&.to_s
      end

    @std_methods = StdMethod.includes(:docker_image, step: :docker_image).order(:name)
    @std_methods = @std_methods.where(version_id: @selected_version_id) if @selected_version_id.present?
  end

  def show
  end

  def new
    @std_method = StdMethod.new
    @std_method.version_id = params[:version_id] if params[:version_id].present?
    @std_method.docker_image_id = params[:docker_image_id] if params[:docker_image_id].present?
    load_steps_for_form
  end

  def edit
    load_steps_for_form
  end

  def create
    @std_method = StdMethod.new(std_method_params)
    @std_method.docker_image_id = @std_method.step.docker_image_id if @std_method.step&.docker_image_id.present?

    if @std_method.save
      redirect_to @std_method, notice: 'Standard method was successfully created.'
    else
      load_steps_for_form
      render :new, status: :unprocessable_entity
    end
  end

  def update
    if @std_method.update(std_method_params)
      redirect_to @std_method, notice: 'Standard method was successfully updated.'
    else
      load_steps_for_form
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
      :name, :label, :step_id, :description, :short_label, :command_json, :nber_cores,
      :link, :speed_id, :attrs_json, :attr_layout_json, :obj_attrs_json, :obsolete, :version_id, :docker_image_id
    )
  end

  def load_steps_for_form
    parts = []
    if @std_method.docker_image_id.present?
      parts << Step.where(docker_image_id: @std_method.docker_image_id)
    else
      vids = version_ids_for_step_scope
      parts << Step.where(version_id: vids) if vids.any?
    end
    parts << Step.where(id: @std_method.step_id) if @std_method.step_id.present?

    @steps =
      if parts.empty?
        Step.none
      elsif parts.one?
        parts.first.order(:rank, :name)
      else
        parts.reduce { |acc, scope| acc.or(scope) }.distinct.order(:rank, :name)
      end
  end

  def version_ids_for_step_scope
    return [@std_method.version_id] if @std_method.version_id.present?

    did = @std_method.docker_image_id
    return [] if did.blank?

    version_ids_for_docker_image(did)
  end

  def version_ids_for_docker_image(docker_image_id)
    did = docker_image_id.to_i
    return [] if did.zero?

    Version.all.each_with_object([]) do |version, ids|
      ids << version.id if Basic.get_asap_docker(version)&.id == did
    end
  end
end

