class RunErrorMailer < ApplicationMailer
  def admin_notification(run:)
    assign_run_context(run)
    assign_instance_context

    mail(
      to: admin_report_recipients,
      subject: error_mail_subject('ASAP Run Error', run)
    )
  end

  def user_report(run:, sender_email:, message: nil, reporter: nil, x_real_ip: nil)
    assign_run_context(run)
    assign_instance_context
    @sender_email = sender_email
    @message = message
    @reporter = reporter
    @x_real_ip = x_real_ip

    mail(
      to: admin_report_recipients,
      reply_to: sender_email,
      subject: error_mail_subject('ASAP Bug Report', run)
    )
  end

  private

  def assign_run_context(run)
    @run = run
    @project = run.project
    @step = run.step
    @error_message = run_error_text(run)
  end

  def assign_instance_context
    @instance_kind = EnvHelpers.instance_kind
    @instance_name = EnvHelpers.instance_name
    @instance_host = EnvHelpers.instance_host
  end

  def error_mail_subject(prefix, run)
    "[#{prefix}] [#{@instance_kind}] #{@project.key} - #{@step&.name || 'unknown step'} (Run ##{run.id})"
  end

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
