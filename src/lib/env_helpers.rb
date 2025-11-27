module EnvHelpers
  module_function

  def email_list(key)
    ENV.fetch(key, '').split(',').map(&:strip).reject(&:empty?)
  end
end

