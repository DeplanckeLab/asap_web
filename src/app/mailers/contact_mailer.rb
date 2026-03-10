class ContactMailer < ApplicationMailer
  def contact_email(sender_email:, subject:, body:, attachments_data: [])
    @sender_email = sender_email
    @subject = subject
    @body = body

    attachments_data.each do |file|
      attachments[file[:filename]] = {
        mime_type: file[:content_type],
        content: file[:content]
      }
    end

    recipients = feedback_recipients

    mail(
      to: recipients,
      reply_to: sender_email,
      subject: "[ASAP Feedback] #{subject}"
    )
  end

  private

  def feedback_recipients
    raw_recipients = ENV.fetch('FEEDBACK_EMAILS').to_s
    recipients = raw_recipients.split(',').map(&:strip).reject(&:blank?)

    if recipients.empty?
      raise ArgumentError, "FEEDBACK_EMAILS is configured but empty."
    end

    recipients
  end
end
