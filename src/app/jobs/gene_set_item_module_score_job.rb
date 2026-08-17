# frozen_string_literal: true

class GeneSetItemModuleScoreJob < ApplicationJob
  queue_as :default

  limits_concurrency to: 1, key: ->(request_id) { "module-score-#{request_id}" }, duration: 2.hours

  def perform(request_record_id)
    request = ModuleScoreRequest.find_by(id: request_record_id)
    unless request
      Rails.logger.error("[GeneSetItemModuleScoreJob] ModuleScoreRequest##{request_record_id} not found")
      return
    end
    return if request.terminal?

    request.update!(status: 'running', error_message: nil)
    scores = GeneSetItemModuleScore.new(request).call
    return if request.reload.canceled?

    result_path = request.write_scores!(scores)
    request.update!(status: 'completed', result_path: result_path, pid: nil)
  rescue StandardError => e
    Rails.logger.error("[GeneSetItemModuleScoreJob] request=#{request_record_id}: #{e.class} - #{e.message}")
    Rails.logger.error(e.backtrace.join("\n")) if e.backtrace
    if request && !request.reload.canceled?
      request.update!(status: 'failed', error_message: e.message, pid: nil)
    end
  end
end
