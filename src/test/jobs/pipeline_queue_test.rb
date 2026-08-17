# frozen_string_literal: true

require 'test_helper'

class PipelineQueueTest < ActiveSupport::TestCase
  test 'parsing and slurm jobs use the pipeline queue' do
    assert_equal 'pipeline', ProjectParsingJob.new.queue_name
    assert_equal 'pipeline', RunExecutionJob.new.queue_name
    assert_equal 'pipeline', SlurmJobMonitorJob.new.queue_name
  end

  test 'catalog import stays on default so it cannot starve pipeline workers' do
    assert_equal 'default', ExternalCatalogImportCandidateJob.new.queue_name
  end
end
