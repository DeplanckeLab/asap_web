class VersionsController < ApplicationController
  before_action :set_version, only: [:show, :edit, :update, :destroy, :run_stats]
  before_action :load_tool_metadata, only: [:index, :show]
  before_action :ensure_admin!, except: [:index, :show, :last_version, :run_stats]
  helper_method :tool_metadata_for, :docker_image_record_for

  def index
    @versions = Version.order(release_date: :desc, created_at: :desc)
    @env_data_by_version_id = @versions.each_with_object({}) do |version, hash|
      hash[version.id] = parse_env_json(version)
    end
  end

  def show
    @env_data = parse_env_json(@version)
    respond_to do |format|
      format.html
      format.json do
        render json: {
          id: @version.id,
          release_date: @version.release_date,
          description: @version.description,
          activated: @version.activated,
          beta: @version.beta,
          activated_at: @version.activated_at,
          created_at: @version.created_at,
          updated_at: @version.updated_at,
          env_json: @env_data,
          tools_json: Basic.safe_parse_json(@version.tools_json, {}),
          docker_json: Basic.safe_parse_json(@version.docker_json, {})
        }
      end
    end
  end

  def new
    @version = Version.new
    @version.release_date ||= Time.current
  end

  def edit; end

  def create
    @version = Version.new(version_params)
    merge_compliance_schemas(@version)
    if @version.save
      redirect_to @version, notice: 'Version was successfully created.'
    else
      render :new, status: :unprocessable_entity
    end
  end

  def update
    @version.assign_attributes(version_params)
    merge_compliance_schemas(@version)
    if @version.save
      redirect_to @version, notice: 'Version was successfully updated.'
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @version.destroy
    redirect_to versions_url, notice: 'Version was successfully destroyed.'
  end

  def last_version
    @version = Version.order(release_date: :desc).first
    respond_to do |format|
      format.html { render(@version ? :show : :index) }
      format.json { render json: @version }
    end
  end

  def run_stats
    render json: []
  end

  private

  def set_version
    @version = Version.find(params[:id])
  end

  def ensure_admin!
    return if admin?

    redirect_to versions_path, alert: 'You are not authorized to perform this action.'
  end

  def version_params
    params.require(:version).permit(
      :release_date,
      :description,
      :tools_json,
      :docker_json,
      :env_json,
      :activated,
      :beta,
      :activated_at,
      :tool_type_id,
      :step_id
    )
  end

  def parse_env_json(version)
    Basic.safe_parse_json(version.env_json, {})
  rescue StandardError
    {}
  end

  # Merge compliance schema form fields into env_json['compliance']
  # Structure: { "compliance": { "<project_type_id>": [ { schema_object }, ... ] } }
  def merge_compliance_schemas(version)
    env_data = Basic.safe_parse_json(version.env_json, {})
    env_data['compliance'] ||= {}

    # Single-cell transcriptomics (project_type_id = 1)
    sc_name = params[:compliance_sc_name]&.strip.presence
    sc_version = params[:compliance_sc_version]&.strip.presence
    sc_source_schema_name = params[:compliance_sc_source_schema_name]&.strip.presence
    sc_description = params[:compliance_sc_description]&.strip.presence
    sc_source_url = params[:compliance_sc_source_url]&.strip.presence
    sc_url = params[:compliance_sc_url]&.strip.presence
    sc_compliant_icon = params[:compliance_sc_compliant_icon]&.strip.presence
    sc_not_compliant_icon = params[:compliance_sc_not_compliant_icon]&.strip.presence

    if sc_name || sc_version || sc_source_url
      schema_entry = {
        'name' => sc_name,
        'version' => sc_version,
        'source_schema_name' => sc_source_schema_name,
        'description' => sc_description,
        'source_url' => sc_source_url,
        'url' => sc_url,
        'compliant_icon' => sc_compliant_icon,
        'not_compliant_icon' => sc_not_compliant_icon,
        'if_compliant' => ['allow_public']
      }.compact
      # Replace the array for project_type_id "1" (single schema for now)
      env_data['compliance']['1'] = [schema_entry]
    end

    # Clean up empty compliance hash
    env_data.delete('compliance') if env_data['compliance'].empty?

    # Remove old structures if present
    env_data.delete('validation')
    env_data.delete('cxg_schema_version')

    version.env_json = JSON.generate(env_data)
  rescue StandardError => e
    Rails.logger.error("Failed to merge compliance schemas: #{e.message}")
  end

  def load_tool_metadata
    @tool_by_name = Tool.all.index_by(&:name)
    @tool_type_by_id = ToolType.all.index_by(&:id)
    @docker_image_lookup = {}
    @docker_image_lookup_by_version = {}
    DockerImage.find_each do |image|
      @docker_image_lookup[[image.name, image.tag]] = image
      @docker_image_lookup[[image.name, nil]] ||= image
      # Also index by name and version for lookup
      if image.version.present?
        @docker_image_lookup_by_version[[image.name, image.version]] = image
      end
    end
  end

  def tool_metadata_for(tool_name)
    tool = @tool_by_name[tool_name]
    return { label: tool_name, package: tool_name, language: 'Other', url: nil, id: nil, tool: nil } unless tool

    {
      label: tool.label.presence || tool.name,
      package: tool.package.presence || tool.name,
      language: @tool_type_by_id[tool.tool_type_id]&.name || tool.language || 'Other',
      url: tool.url,
      id: tool.id,
      tool: tool
    }
  end

  def docker_image_record_for(name, metadata = {}, release_version = nil)
    return nil unless name

    metadata = metadata.is_a?(Hash) ? metadata : {}
    tag = metadata['tag']
    version = metadata['version']
    
    # Priority 1: Try lookup by name and release version first (most reliable)
    # This ensures version 8 uses the DockerImage with version 8, not what's in env_json
    if release_version.present?
      record = @docker_image_lookup_by_version[[name, release_version]]
      return record if record
    end
    
    # Priority 2: Try lookup by name and tag from metadata
    if tag.present?
      record = @docker_image_lookup[[name, tag]]
      return record if record
    end
    
    # Priority 3: Try lookup by name and version from metadata
    if version.present?
      record = @docker_image_lookup_by_version[[name, version]]
      return record if record
    end
    
    # Fallback to name only
    @docker_image_lookup[[name, nil]]
  end
end

