class RunErrorNotifier
  def self.notify_admins!(run)
    new(run).notify_admins!
  end

  def initialize(run)
    @run = run
  end

  def notify_admins!
    return unless @run.status_id == 4

    RunErrorMailer.admin_notification(run: @run).deliver_now
  rescue KeyError, ArgumentError => e
    Rails.logger.error("[RunErrorNotifier] Invalid mail configuration: #{e.class} - #{e.message}")
  rescue StandardError => e
    Rails.logger.error("[RunErrorNotifier] Failed to send admin notification for Run##{@run.id}: #{e.class} - #{e.message}")
  end
end
