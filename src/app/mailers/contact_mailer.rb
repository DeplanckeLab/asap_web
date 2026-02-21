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

    recipients = ENV.fetch('FEEDBACK_EMAILS').split(',').map(&:strip)

    mail(
      to: recipients,
      reply_to: sender_email,
      subject: "[ASAP Feedback] #{subject}"
    )
  end
end
