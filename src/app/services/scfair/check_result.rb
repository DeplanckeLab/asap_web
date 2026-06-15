# frozen_string_literal: true

module Scfair
  # Builds structured compliance check entries with stable check_id and message templates.
  module CheckResult
    module_function

    def build(check_id:, field:, status:, code:, format:, message: nil, **message_kwargs)
      entry = {
        check_id: check_id.to_s,
        field: field.to_s,
        status: status.to_s,
        code: code.to_s
      }
      entry[:message] = message.presence || Rules.check_message(
        check_id,
        code,
        format: format,
        field: field,
        path: field,
        **message_kwargs
      )
      entry
    end

    def presence(field:, format:, status:, code:, message: nil, **message_kwargs)
      check_id = Rules.presence_check_id_for_field(field, format)
      build(
        check_id: check_id,
        field: field,
        status: status,
        code: code,
        format: format,
        message: message,
        **message_kwargs
      )
    end

    def ontology_format(field:, format:, status:, code:, message: nil, **message_kwargs)
      build(
        check_id: Rules::ONTOLOGY_FORMAT_CHECK_ID,
        field: field,
        status: status,
        code: code,
        format: format,
        message: message,
        field_name: field.to_s.split('/').last,
        **message_kwargs
      )
    end
  end
end
