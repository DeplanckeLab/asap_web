class ApplicationMailer < ActionMailer::Base
  default from: ENV.fetch('ACTION_MAILER_DEFAULT_FROM', 'noreply@epfl.ch')
  layout "mailer"

  def default_url_options
    { protocol: 'https', host: EnvHelpers.instance_host }
  end
end
