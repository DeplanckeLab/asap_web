class FuPreparsingJob < ApplicationJob
  queue_as :default

  def perform(fu_id, options = {})
    Rails.logger.info("[FuPreparsingJob] Starting job for Fu##{fu_id}")
    Rails.logger.info("[FuPreparsingJob] Options received: #{options.inspect}")
    
    fu = Fu.find_by(id: fu_id)
    return unless fu

    broadcast(fu.id, status: 'started')

    symbolized_options = options.deep_symbolize_keys
    Rails.logger.info("[FuPreparsingJob] Symbolized options: #{symbolized_options.inspect}")
    Rails.logger.info("[FuPreparsingJob] version_id: #{symbolized_options[:version_id].inspect}")
    Rails.logger.info("[FuPreparsingJob] organism_id: #{symbolized_options[:organism_id].inspect}")

    result = FuPreparsingService.new(fu, symbolized_options).call
    fu.update!(status: 'preparsed')
    broadcast(fu.id, status: 'completed', summary: result[:summary], warnings: result[:warnings], raw_output: result[:raw_output], prediction_debug: result[:summary][:prediction_debug])
  rescue StandardError => e
    Rails.logger.error("[FuPreparsingJob] #{e.class}: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n")) if e.backtrace

    fu&.update!(status: 'preparsing_failed')
    broadcast(fu&.id, status: 'failed', error: e.message) if fu
  end

  private

  def broadcast(fu_id, payload)
    ActionCable.server.broadcast("fu_#{fu_id}", payload.merge(fu_id: fu_id, stage: 'preparsing'))
  end
end

