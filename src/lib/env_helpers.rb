module EnvHelpers
  module_function

  PRODUCTION_HOST = 'asap.epfl.ch'

  def email_list(key)
    ENV.fetch(key, '').split(',').map(&:strip).reject(&:empty?)
  end

  def instance_host
    ENV.fetch('HOST')
  end

  def instance_name
    ENV.fetch('ASAP_INSTANCE_NAME')
  end

  def instance_kind
    instance_host == PRODUCTION_HOST ? 'production' : 'dev/test'
  end

  # Public origin for this instance. HOST is the external hostname
  # (asap-test.epfl.ch / asap.epfl.ch). SERVER_URL is not used here because
  # it can point at another instance (e.g. production on the test .env).
  def public_base_url
    "https://#{instance_host}"
  end
end

