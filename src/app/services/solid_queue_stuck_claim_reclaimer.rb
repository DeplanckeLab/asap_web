# frozen_string_literal: true

# Fails Solid Queue claimed executions older than max_age so a hung worker thread
# cannot hold pipeline capacity forever. Also logs long-lived ASAP H5 docker/python
# orphans for operators (detection only; does not kill).
class SolidQueueStuckClaimReclaimer
  DEFAULT_MAX_AGE = 6.hours
  H5_ORPHAN_CMD_PATTERN = /anndata_mapping|\.asap_global_attr_read_|\.asap_global_attr_write_|\.asap_global_attrs_/.freeze

  def self.call(max_age: DEFAULT_MAX_AGE, logger: Rails.logger)
    new(max_age: max_age, logger: logger).call
  end

  def initialize(max_age: DEFAULT_MAX_AGE, logger: Rails.logger)
    @max_age = max_age.is_a?(ActiveSupport::Duration) ? max_age : max_age.to_i.seconds
    @logger = logger
  end

  def call
    cutoff = Time.current - @max_age
    claimed = SolidQueue::ClaimedExecution
              .joins(:job)
              .includes(:job)
              .where('solid_queue_claimed_executions.created_at < ?', cutoff)
              .to_a

    claimed.each do |execution|
      job = execution.job
      @logger.error(
        '[SolidQueueStuckClaimReclaimer] reclaiming stuck claimed execution ' \
        "claimed_execution_id=#{execution.id} job_id=#{job&.id} class=#{job&.class_name} " \
        "queue=#{job&.queue_name} claimed_at=#{execution.created_at} " \
        "args=#{job&.arguments.to_s[0, 300]}"
      )
    end

    failed = 0
    if claimed.any?
      error = StandardError.new(
        "Claimed execution older than #{@max_age.inspect}; reclaimed as stuck"
      )
      SolidQueue::ClaimedExecution.where(id: claimed.map(&:id)).fail_all_with(error)
      failed = claimed.size
    end

    orphans = log_orphan_h5_processes!(max_age_seconds: @max_age.to_i)
    {
      failed_claimed: failed,
      logged_h5_orphans: orphans
    }
  end

  private

  def log_orphan_h5_processes!(max_age_seconds:)
    rows = host_process_rows
    return 0 if rows.empty?

    logged = 0
    rows.each do |row|
      next if row[:etimes] < max_age_seconds
      next unless row[:cmd].match?(H5_ORPHAN_CMD_PATTERN)

      @logger.error(
        '[SolidQueueStuckClaimReclaimer] long-lived H5-related process ' \
        "pid=#{row[:pid]} etimes=#{row[:etimes]}s cmd=#{row[:cmd][0, 400]}"
      )
      logged += 1
    end
    logged
  end

  def host_process_rows
    out = `ps -eo pid=,etimes=,cmd= 2>/dev/null`
    return [] if out.blank?

    out.each_line.filter_map do |line|
      m = line.strip.match(/\A(\d+)\s+(\d+)\s+(.+)\z/)
      next unless m

      { pid: m[1].to_i, etimes: m[2].to_i, cmd: m[3] }
    end
  rescue StandardError => e
    @logger.warn("[SolidQueueStuckClaimReclaimer] ps failed: #{e.class}: #{e.message}")
    []
  end
end
