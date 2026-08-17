# Re-enqueue in-progress work when the Solid Queue worker starts.
# Website/Puma does not run this: a website-only restart must not duplicate
# jobs the worker is still processing. Full compose restart starts `jobs`,
# which holds the Postgres advisory lock and recovers from durable DB flags.

Rails.application.config.after_initialize do
  next unless InterruptedJobRecovery.worker_process?

  Thread.new do
    sleep 5
    Rails.application.executor.wrap do
      ActiveRecord::Base.connection_pool.with_connection do |conn|
        raw = conn.select_value("SELECT pg_try_advisory_lock(#{InterruptedJobRecovery::LOCK_KEY})")
        acquired = raw == true || raw.to_s == 't' || raw.to_s == 'true'
        unless acquired
          Rails.logger.info("[InterruptedJobRecovery] another process already holds the recovery lock, skipping (pid=#{Process.pid})")
          next
        end

        begin
          Rails.logger.info("[InterruptedJobRecovery] starting boot recovery (pid=#{Process.pid})")
          InterruptedJobRecovery.call
          Rails.logger.info('[InterruptedJobRecovery] boot recovery done')
        rescue StandardError => e
          Rails.logger.error("[InterruptedJobRecovery] boot recovery failed: #{e.class} - #{e.message}")
          Rails.logger.error(e.backtrace.join("\n")) if e.backtrace
        ensure
          conn.execute("SELECT pg_advisory_unlock(#{InterruptedJobRecovery::LOCK_KEY})")
        end
      end
    end
  end
end
