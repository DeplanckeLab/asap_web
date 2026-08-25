class ToolTypesController < ApplicationController
  before_action :set_tool_type, only: [:show, :edit, :update, :destroy]
  before_action :ensure_admin!, except: [:index, :show]
  before_action :ensure_synced_reference_data_writable!, except: [:index, :show]

  def index
    @tool_types = ToolType.includes(:tools).order(:name)
  end

  def show
  end

  def new
    @tool_type = ToolType.new
  end

  def edit
  end

  def create
    @tool_type = ToolType.new(tool_type_params)
    if @tool_type.save
      redirect_to @tool_type, notice: 'Tool type was successfully created.'
    else
      render :new, status: :unprocessable_entity
    end
  end

  def update
    if @tool_type.update(tool_type_params)
      redirect_to @tool_type, notice: 'Tool type was successfully updated.'
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @tool_type.destroy
    redirect_to tool_types_url, notice: 'Tool type was successfully destroyed.'
  end

  private

  def set_tool_type
    @tool_type = ToolType.find(params[:id])
  end

  def ensure_admin!
    return if admin?

    redirect_to tool_types_path, alert: 'You are not authorized to perform this action.'
  end

  def tool_type_params
    params.require(:tool_type).permit(:name)
  end
end

