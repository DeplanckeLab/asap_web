class RunErrorMailer < ApplicationMailer
  include Rails.application.routes.url_helpers

  def admin_notification(run:)
    @run = run
    @project = run.project
    @step = run.step
    @error_message = run_error_text(run)

    mail(
      to: admin_report_recipients,
      subject: "[ASAP Run Error] #{@project.key} - #{@step&.name || 'unknown step'} (Run ##{run.id})"
    )
  end

  def user_report(run:, sender_email:, message: nil)
    @run = run
    @project = run.project
    @step = run.step
    @sender_email = sender_email
    @message = message
    @error_message = run_error_text(run)

    mail(
      to: admin_report_recipients,
      reply_to: sender_email,
      subject: "[ASAP Bug Report] #{@project.key} - #{@step&.name || 'unknown step'} (Run ##{run.id})"
    )
  end

  private

  def admin_report_recipients
    recipients = EnvHelpers.email_list('ADMIN_REPORT_EMAILS')
    if recipients.empty?
      raise ArgumentError, "ADMIN_REPORT_EMAILS is configured but empty."
    end

    recipients
  end

  def run_error_text(run)
    return run.error if run.error.present?

    output = Basic.safe_parse_json(run.output_json, {})
    displayed_error = output['displayed_error']
    case displayed_error
    when Array
      displayed_error.compact.join("\n")
    when String, Numeric
      displayed_error.to_s
    else
      'No error details available.'
    end
  end
end
