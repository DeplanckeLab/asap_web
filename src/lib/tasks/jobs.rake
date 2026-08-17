# frozen_string_literal: true

namespace :jobs do
  desc 'Re-enqueue in-progress work from durable DB flags (same as Solid Queue worker boot recovery)'
  task recover: :environment do
    InterruptedJobRecovery.call
  end
end
