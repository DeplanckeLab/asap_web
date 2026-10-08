# frozen_string_literal: true

require 'test_helper'

class SolidQueueStuckClaimReclaimerTest < ActiveSupport::TestCase
  test 'call fails claimed executions older than max_age' do
    job = SolidQueue::Job.create!(
      queue_name: 'pipeline',
      class_name: 'ProjectParsingJob',
      arguments: { 'job_class' => 'ProjectParsingJob', 'arguments' => [1] },
      priority: 0,
      active_job_id: SecureRandom.uuid,
      scheduled_at: 7.hours.ago,
      created_at: 7.hours.ago,
      updated_at: 7.hours.ago
    )
    process = SolidQueue::Process.create!(
      kind: 'Worker',
      name: "test-worker-#{SecureRandom.hex(4)}",
      pid: Process.pid,
      hostname: 'test',
      last_heartbeat_at: Time.current,
      metadata: { 'queues' => 'pipeline' }
    )
    claimed = SolidQueue::ClaimedExecution.create!(
      job_id: job.id,
      process_id: process.id,
      created_at: 7.hours.ago
    )

    # May also reclaim unrelated stuck claims in a shared DB; assert only our row.
    SolidQueueStuckClaimReclaimer.call(max_age: 6.hours)

    assert_nil SolidQueue::ClaimedExecution.find_by(id: claimed.id)
    assert SolidQueue::FailedExecution.exists?(job_id: job.id)
  ensure
    SolidQueue::FailedExecution.where(job_id: job&.id).delete_all if job
    SolidQueue::ClaimedExecution.where(job_id: job&.id).delete_all if job
    job&.delete
    process&.delete
  end

  test 'call with very large max_age finds no stuck claims from age filter alone' do
    before = SolidQueue::ClaimedExecution
             .joins(:job)
             .where('solid_queue_claimed_executions.created_at < ?', Time.current - 100.years)
             .count
    assert_equal 0, before

    result = SolidQueueStuckClaimReclaimer.call(max_age: 100.years)
    assert_equal 0, result[:failed_claimed]
    assert result.key?(:logged_h5_orphans)
  end
end
