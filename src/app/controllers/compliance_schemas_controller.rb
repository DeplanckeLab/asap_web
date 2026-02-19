class ComplianceSchemasController < ApplicationController
  before_action :ensure_admin!
  before_action :set_compliance_schema, only: [:show, :edit, :update]

  def index
    @compliance_schemas = ComplianceSchema.order(active: :desc, started_at: :desc, created_at: :desc)
  end

  def show; end

  def new
    @compliance_schema = ComplianceSchema.new(active: true, started_at: Time.current)
  end

  def create
    @compliance_schema = ComplianceSchema.new(compliance_schema_params)
    if @compliance_schema.save
      redirect_to compliance_schemas_path, notice: 'Compliance schema was successfully created.'
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit; end

  def update
    if @compliance_schema.update(compliance_schema_params)
      redirect_to compliance_schemas_path, notice: 'Compliance schema was successfully updated.'
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def set_compliance_schema
    @compliance_schema = ComplianceSchema.find(params[:id])
  end

  def ensure_admin!
    return if admin?
    redirect_to root_path, alert: 'You are not authorized to perform this action.'
  end

  def compliance_schema_params
    params.require(:compliance_schema).permit(
      :name, :version, :source_schema_name, :description,
      :source_url, :url, :compliant_icon, :not_compliant_icon,
      :project_type_tags, :if_compliant, :active, :started_at, :ended_at
    )
  end
end
