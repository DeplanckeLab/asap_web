class Version < ApplicationRecord
  scope :activated, -> { where(activated: true) }

  # Get the parsed env_json as a hash
  def env_data
    @env_data ||= (env_json.is_a?(Hash) ? env_json : JSON.parse(env_json.presence || '{}'))
  rescue JSON::ParserError
    {}
  end

  # Deprecated: compliance schemas now live in the compliance_schemas table.
  # These methods are kept for backward compatibility during migration.
  def compliance_schemas_for(_project_type_id)
    []
  end

  def compliance_requires_public?(_project_type_id)
    false
  end
end
