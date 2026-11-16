# frozen_string_literal: true

require 'test_helper'

class PipelineQueueTest < ActiveSupport::TestCase
  test 'parsing and slurm jobs use the pipeline queues' do
    assert_equal 'pipeline', ProjectParsingJob.new.queue_name
    assert_equal 'pipeline', RunExecutionJob.new.queue_name
    # Own queue (config/queue.yml) so SLURM polling is never stuck behind long pipeline jobs.
    assert_equal 'pipeline_monitor', SlurmJobMonitorJob.new.queue_name
  end

  test 'catalog import stays on default so it cannot starve pipeline workers' do
    assert_equal 'default', ExternalCatalogImportCandidateJob.new.queue_name
  end
end
