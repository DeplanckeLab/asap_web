# Re-kick the existing SLURM rake tasks once, inside the web server process,
# to recover runs that were in-flight when Rails was stopped.
#
# The default ActiveJob queue adapter is :async, so the thread pool running
# SlurmJobMonitorJob / RunExecutionJob dies with the web server. SLURM keeps
# running / queuing the underlying jobs, but nothing on the Rails side is
# watching them anymore. Invoking these tasks from inside Puma enqueues the
# jobs into the same :async pool that will actually execute them.
#
#   - slurm:process_waiting_runs: re-enqueues RunExecutionJob for runs in
#     status_id=1 that never made it to sbatch (slurm_job_id is null).
#   - slurm:monitor_jobs: re-enqueues SlurmJobMonitorJob for runs in
#     status_id=2 so polling + broadcasting resumes.
#
# Constraints:
#   - Must not run from rake tasks, console, runner, tailwindcss:watch,
#     migrations, asset precompile, etc.: any .perform_later call from
#     those processes would be lost when they exit. We detect the web
#     server by the presence of the Puma constant, which is only loaded
#     for `bin/rails server`.
#   - Puma runs in cluster mode (WEB_CONCURRENCY=5), so without protection
#     each worker would fire the tasks and process_waiting_runs would
#     submit the same runs to SLURM N times. We use a Postgres advisory
#     lock so only the first worker to reach the recovery block actually
#     runs it; the others observe the lock and skip.

Rails.application.config.after_initialize do
  # Puma is only loaded by `bin/rails server`, not by rake / console /
  # runner / tailwindcss:watch. This is the cheapest reliable signal that
  # we are inside the actual web server process.
  next unless defined?(::Puma)

  Thread.new do
    sleep 5
    lock_key = 0x5A5A_5A5A # arbitrary, stable across restarts
    Rails.application.executor.wrap do
      ActiveRecord::Base.connection_pool.with_connection do |conn|
        raw = conn.select_value("SELECT pg_try_advisory_lock(#{lock_key})")
        acquired = raw == true || raw.to_s == 't' || raw.to_s == 'true'
        unless acquired
          Rails.logger.info("[RecoverInterruptedRuns] another worker already holds the recovery lock, skipping (pid=#{Process.pid})")
          next
        end

        begin
          Rails.logger.info("[RecoverInterruptedRuns] starting boot recovery (pid=#{Process.pid})")
          require 'rake'
          Rake::TaskManager.record_task_metadata = true
          Rails.application.load_tasks unless Rake::Task.task_defined?('slurm:monitor_jobs')
          %w[slurm:process_waiting_runs slurm:monitor_jobs].each do |task_name|
            begin
              task = Rake::Task[task_name]
              task.reenable
              task.invoke
            rescue SystemExit
              # Both tasks call `exit 0` when there is nothing to do; treat
              # that as a normal completion for this task and keep going
              # with the next one.
              Rails.logger.info("[RecoverInterruptedRuns] #{task_name} finished (called exit)")
            end
          end
          Rails.logger.info('[RecoverInterruptedRuns] boot recovery done')
        rescue StandardError => e
          Rails.logger.error("[RecoverInterruptedRuns] boot recovery failed: #{e.class} - #{e.message}")
          Rails.logger.error(e.backtrace.join("\n")) if e.backtrace
        ensure
          conn.execute("SELECT pg_advisory_unlock(#{lock_key})")
        end
      end
    end
  end
end
