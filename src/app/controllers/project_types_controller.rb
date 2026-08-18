class ProjectTypesController < ApplicationController
  before_action :authorize_admin, except: %i[index show]
  before_action :ensure_synced_reference_data_writable!, except: %i[index show]
  before_action :set_project_type, only: %i[show edit update destroy]

  # GET /project_types or /project_types.json
  def index
    @project_types = ProjectType.order(:name)
    @project_counts = ProjectType.project_visibility_counts_for(@project_types)
  end

  # GET /project_types/1 or /project_types/1.json
  def show
    @project_counts = ProjectType.project_visibility_counts_for([@project_type]).fetch(@project_type.id)
  end

  # GET /project_types/new
  def new
    @project_type = ProjectType.new
  end

  # GET /project_types/1/edit
  def edit
  end

  # POST /project_types or /project_types.json
  def create
    @project_type = ProjectType.new(project_type_params)

    respond_to do |format|
      if @project_type.save
        format.html { redirect_to project_type_url(@project_type), notice: "Project type was successfully created." }
        format.json { render :show, status: :created, location: @project_type }
      else
        format.html { render :new, status: :unprocessable_entity }
        format.json { render json: @project_type.errors, status: :unprocessable_entity }
      end
    end
  end

  # PATCH/PUT /project_types/1 or /project_types/1.json
  def update
    respond_to do |format|
      if @project_type.update(project_type_params)
        format.html { redirect_to project_type_url(@project_type), notice: "Project type was successfully updated." }
        format.json { render :show, status: :ok, location: @project_type }
      else
        format.html { render :edit, status: :unprocessable_entity }
        format.json { render json: @project_type.errors, status: :unprocessable_entity }
      end
    end
  end

  # DELETE /project_types/1 or /project_types/1.json
  def destroy
    if @project_type.projects.exists?
      message = "Cannot delete #{@project_type.name}: projects still use this type."
      respond_to do |format|
        format.html { redirect_to project_types_url, alert: message }
        format.json { render json: { error: message }, status: :unprocessable_entity }
      end
      return
    end

    @project_type.destroy!

    respond_to do |format|
      format.html { redirect_to project_types_url, notice: "Project type was successfully destroyed." }
      format.json { head :no_content }
    end
  end

  private

  def set_project_type
    @project_type = ProjectType.find(params[:id])
  end

  def project_type_params
    params.fetch(:project_type, {}).permit(:name, :tag, :row_label, :col_label, :admin_report_only)
  end
end
