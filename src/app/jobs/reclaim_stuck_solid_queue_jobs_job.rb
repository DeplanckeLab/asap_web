# frozen_string_literal: true

class ReclaimStuckSolidQueueJobsJob < ApplicationJob
  queue_as :default

  def perform(max_age_seconds = SolidQueueStuckClaimReclaimer::DEFAULT_MAX_AGE.to_i)
    result = SolidQueueStuckClaimReclaimer.call(max_age: max_age_seconds.to_i.seconds)
    Rails.logger.info(
      '[ReclaimStuckSolidQueueJobsJob] ' \
      "failed_claimed=#{result[:failed_claimed]} logged_h5_orphans=#{result[:logged_h5_orphans]}"
    )
    result
  end
end
