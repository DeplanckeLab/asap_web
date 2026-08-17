class ApplicationJob < ActiveJob::Base
  retry_on SolidQueue::Processes::ProcessPrunedError, wait: 5.seconds, attempts: 5
end
