require 'active_support/core_ext/object/blank'

REQUIRED_ENV_VARS = %w[
  UPLOAD_DATA_DIR
  USER_DATA_DIR
  LOCAL_ASAP_RUN_DIR
  ASAP_DOCKER_NAME
  DOCKER_CALL
  ASAP_INSTANCE_NAME
  SERVER_URL
].freeze

missing_keys = REQUIRED_ENV_VARS.select { |key| ENV[key].blank? }

if missing_keys.any?
  raise "Missing required environment variables: #{missing_keys.join(', ')}"
end

