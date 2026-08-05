# frozen_string_literal: true

# Persists standalone (non-project) scFAIR check outcomes without keeping the file.
# Omits field_values and checks_catalog from result_json — those are large and
# reconstructible; errors/warnings/valid_checks/summary are the durable outcome.
class StandaloneComplianceCheckRecorder
  OMIT_RESULT_KEYS = %w[field_values checks_catalog].freeze

  class << self
    def record_completed!(task_id:, result:, filename:, schema_id:, user_id: nil, source_url: nil, fu_id: nil)
      StandaloneComplianceCheck.create!(
        task_id: task_id,
        filename: filename,
        schema_id: schema_id.to_s.presence || result.fetch(:schema_id) { result.fetch('schema_id') },
        user_id: user_id,
        source_url: source_url,
        fu_id: fu_id,
        format: result.fetch(:format) { result.fetch('format') },
        passed: ActiveModel::Type::Boolean.new.cast(result.fetch(:valid) { result.fetch('valid') }),
        status: 'completed',
        checked_at: parse_checked_at(result.fetch(:validated_at) { result.fetch('validated_at') }),
        result_json: persistable_result(result)
      )
    end

    def record_failed!(task_id:, error_message:, filename: nil, schema_id: nil, user_id: nil, source_url: nil, fu_id: nil, format: nil)
      StandaloneComplianceCheck.create!(
        task_id: task_id,
        filename: filename,
        schema_id: schema_id,
        user_id: user_id,
        source_url: source_url,
        fu_id: fu_id,
        format: format,
        passed: false,
        status: 'failed',
        checked_at: Time.current,
        result_json: {
          'error' => error_message.to_s,
          'valid' => false
        }
      )
    end

    private

    def persistable_result(result)
      hash = result.deep_stringify_keys
      hash.except(*OMIT_RESULT_KEYS)
    end

    def parse_checked_at(value)
      Time.zone.parse(value.to_s)
    end
  end
end
