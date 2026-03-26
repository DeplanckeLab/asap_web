class FuPreparsingJob < ApplicationJob
  queue_as :default

  def perform(fu_id, options = {})
    job_started_at = Time.current
    symbolized_options = options.deep_symbolize_keys
    enqueued_at = parse_time(symbolized_options[:enqueued_at])
    queue_wait_ms = enqueued_at ? ((job_started_at - enqueued_at) * 1000).round : nil

    Rails.logger.info("[FuPreparsingJob] Starting job for Fu##{fu_id} job_id=#{job_id} started_at=#{job_started_at.utc.iso8601} queue_wait_ms=#{queue_wait_ms || 'unknown'}")
    Rails.logger.info("[FuPreparsingJob] Options received: #{options.inspect}")
    
    fu = Fu.find_by(id: fu_id)
    return unless fu

    broadcast(fu.id, status: 'started')

    Rails.logger.info("[FuPreparsingJob] Symbolized options: #{symbolized_options.inspect}")
    Rails.logger.info("[FuPreparsingJob] version_id: #{symbolized_options[:version_id].inspect}")
    Rails.logger.info("[FuPreparsingJob] organism_id: #{symbolized_options[:organism_id].inspect}")

    result = FuPreparsingService.new(fu, symbolized_options).call
    fu.update!(status: 'preparsed')
    job_elapsed_ms = ((Time.current - job_started_at) * 1000).round
    Rails.logger.info("[FuPreparsingJob] Completed Fu##{fu_id} job_id=#{job_id} status=preparsed job_elapsed_ms=#{job_elapsed_ms}")
    broadcast(fu.id, status: 'completed', summary: result[:summary], warnings: result[:warnings], raw_output: result[:raw_output], prediction_debug: result[:summary][:prediction_debug])
  rescue StandardError => e
    Rails.logger.error("[FuPreparsingJob] #{e.class}: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n")) if e.backtrace

    fu&.update!(status: 'preparsing_failed')
    job_elapsed_ms = ((Time.current - job_started_at) * 1000).round rescue nil
    Rails.logger.error("[FuPreparsingJob] Failed Fu##{fu_id} job_id=#{job_id} job_elapsed_ms=#{job_elapsed_ms || 'unknown'}")
    broadcast(fu&.id, status: 'failed', error: e.message) if fu
  end

  private

  def broadcast(fu_id, payload)
    ActionCable.server.broadcast("fu_#{fu_id}", payload.merge(fu_id: fu_id, stage: 'preparsing'))
  end

  def parse_time(value)
    return nil if value.blank?

    Time.zone.parse(value.to_s)
  rescue StandardError
    nil
  end

end

