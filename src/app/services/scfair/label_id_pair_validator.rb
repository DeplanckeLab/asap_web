# frozen_string_literal: true

module Scfair
  class LabelIdPairValidator
    def initialize(field_values:, format:, id_field:, label_field:, check_field:, allowed_special_values: [])
      @field_values = field_values || {}
      @format = format.to_s
      @id_field = id_field.to_s
      @label_field = label_field.to_s
      @check_field = check_field.to_s
      @allowed_special_values = Array(allowed_special_values).map(&:to_s).freeze
    end

    def call
      id_path = path_for(@id_field)
      label_path = path_for(@label_field)
      id_present = @field_values.key?(id_path)

      unless id_present
        return result(
          status: 'skipped',
          message: Rules.label_pair_skip_message(@id_field, format: @format),
          errors: []
        )
      end

      pairs_key = "#{id_path}#label_pairs"
      pair_entries = Array(@field_values[pairs_key]).map(&:to_s).map(&:strip).reject(&:blank?)
      return validate_extracted_pairs(pair_entries) if pair_entries.any?

      unless @field_values.key?(label_path)
        message = Rules.label_pair_missing_label_message(@id_field, @label_field, format: @format)
        return result(status: 'failed', message: message, errors: [{ field: @check_field, message: message }])
      end

      id_values = split_values(@field_values[id_path])
      labels = split_values(@field_values[label_path])
      if labels.empty?
        message = Rules.label_pair_missing_label_message(@id_field, @label_field, format: @format)
        return result(status: 'failed', message: message, errors: [{ field: @check_field, message: message }])
      end

      if labels.size != id_values.size
        message = Rules.label_pair_count_mismatch_message(@id_field, @label_field, format: @format)
        return result(status: 'failed', message: message, errors: [{ field: @check_field, message: message }])
      end

      id_values.each_with_index do |identifier, idx|
        pair_error = validate_label_for_identifier(identifier, labels[idx].to_s)
        return pair_error if pair_error
      end

      result(
        status: 'passed',
        message: Rules.label_pair_pass_message(@id_field, @label_field, format: @format),
        errors: []
      )
    end

    private

    def path_for(field_name)
      Rules.field_path(@format, layer_for(field_name), field_name)
    end

    def layer_for(field_name)
      field_name == 'organism_ontology_term_id' ? :uns : :obs
    end

    def split_values(raw)
      Array(raw).flat_map { |v| v.to_s.split(' || ') }.map(&:strip).reject(&:blank?)
    end

    def validate_extracted_pairs(pair_entries)
      pair_entries.each do |entry|
        id_val, label_val = entry.to_s.split(' || ', 2).map(&:strip)
        next if id_val.blank?

        pair_error = validate_label_for_identifier(id_val, label_val.to_s)
        return pair_error if pair_error
      end

      result(
        status: 'passed',
        message: Rules.label_pair_pass_message(@id_field, @label_field, format: @format),
        errors: []
      )
    end

    def validate_label_for_identifier(identifier, label)
      if special_value?(identifier)
        return nil if label == identifier

        message = Rules.label_pair_special_mismatch_message(identifier, label)
        return result(status: 'failed', message: message, errors: [{ field: @check_field, message: message }])
      end

      term = CellOntologyTerm.active_original_by_identifier(identifier)
      return nil if term && term.name.to_s == label

      expected = term&.name || 'n/a'
      message = Rules.label_pair_mismatch_message(identifier, expected, label)
      result(status: 'failed', message: message, errors: [{ field: @check_field, message: message }])
    end

    def special_value?(value)
      @allowed_special_values.include?(value.to_s)
    end

    def result(status:, message:, errors:)
      {
        errors: errors,
        check: {
          field: @check_field,
          status: status,
          message: message
        }
      }
    end
  end
end
