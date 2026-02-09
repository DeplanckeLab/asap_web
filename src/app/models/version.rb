class Version < ApplicationRecord
  scope :activated, -> { where(activated: true) }

  # Get the parsed env_json as a hash
  def env_data
    @env_data ||= (env_json.is_a?(Hash) ? env_json : JSON.parse(env_json.presence || '{}'))
  rescue JSON::ParserError
    {}
  end

  # Get compliance schemas for a given project_type_id
  # Returns an array of schema hashes, e.g.:
  #   [{ "name" => "...", "version" => "...", "source_url" => "...", "url" => "...",
  #      "compliant_icon" => "...", "not_compliant_icon" => "...",
  #      "if_compliant" => ["allow_public"] }]
  def compliance_schemas_for(project_type_id)
    schemas = env_data.dig('compliance', project_type_id.to_s)
    return [] unless schemas.is_a?(Array)
    schemas
  end

  # Check if any compliance schema for a project type requires "allow_public"
  def compliance_requires_public?(project_type_id)
    schemas = compliance_schemas_for(project_type_id)
    return schemas.any? { |s| s['if_compliant']&.include?('allow_public') } if schemas.any?

    # Backward compatibility: if no compliance config exists but old structures do,
    # single-cell projects (type 1) still require compliance
    if project_type_id.to_i == 1
      env_data.key?('cxg_schema_version') ||
        env_data.dig('validation', 'single_cell').present?
    else
      false
    end
  end
end
