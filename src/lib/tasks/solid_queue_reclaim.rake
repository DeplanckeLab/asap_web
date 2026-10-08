# frozen_string_literal: true

namespace :solid_queue do
  desc 'Fail Solid Queue claimed executions older than MAX_AGE_SECONDS (default 21600 = 6h) ' \
       'and log long-lived H5-related host processes. DRY_RUN=1 only lists.'
  task reclaim_stuck_claims: :environment do
    max_age = Integer(ENV.fetch('MAX_AGE_SECONDS', SolidQueueStuckClaimReclaimer::DEFAULT_MAX_AGE.to_i))
    dry_run = ENV['DRY_RUN'].to_s == '1'
    cutoff = Time.current - max_age.seconds

    claimed = SolidQueue::ClaimedExecution
              .joins(:job)
              .includes(:job)
              .where('solid_queue_claimed_executions.created_at < ?', cutoff)
              .to_a

    puts "cutoff=#{cutoff} max_age_seconds=#{max_age} stuck_claimed=#{claimed.size} dry_run=#{dry_run}"
    claimed.each do |execution|
      job = execution.job
      puts "  claimed_execution_id=#{execution.id} job_id=#{job&.id} class=#{job&.class_name} " \
           "queue=#{job&.queue_name} claimed_at=#{execution.created_at}"
    end

    if dry_run
      puts 'DRY_RUN=1: not failing claimed executions'
    else
      result = SolidQueueStuckClaimReclaimer.call(max_age: max_age.seconds)
      puts "failed_claimed=#{result[:failed_claimed]} logged_h5_orphans=#{result[:logged_h5_orphans]}"
    end
  end
end
