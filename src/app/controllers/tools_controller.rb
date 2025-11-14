class ToolsController < ApplicationController
  before_action :set_tool, only: [:show, :edit, :update, :destroy]
  before_action :ensure_admin!, except: [:index, :show]

  def index
    @tools = Tool.includes(:tool_type).order(:name)
  end

  def show
  end

  def new
    @tool = Tool.new
  end

  def edit
  end

  def create
    @tool = Tool.new(tool_params)
    if @tool.save
      redirect_to @tool, notice: 'Tool was successfully created.'
    else
      render :new, status: :unprocessable_entity
    end
  end

  def update
    if @tool.update(tool_params)
      redirect_to @tool, notice: 'Tool was successfully updated.'
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @tool.destroy
    redirect_to tools_url, notice: 'Tool was successfully destroyed.'
  end

  private

  def set_tool
    @tool = Tool.find(params[:id])
  end

  def ensure_admin!
    return if admin?

    redirect_to tools_path, alert: 'You are not authorized to perform this action.'
  end

  def tool_params
    params.require(:tool).permit(
      :name,
      :label,
      :package,
      :tool_type_id,
      :step_ids,
      :title,
      :description,
      :url,
      :tag
    )
  end
end

