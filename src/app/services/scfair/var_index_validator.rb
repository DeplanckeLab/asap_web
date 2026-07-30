# frozen_string_literal: true

module Scfair
  # Validates var pandas.DataFrame index: presence, uniqueness, and per-feature format.
  class VarIndexValidator
    CHECK_PREFIX = 'var.index'
    SPIKE_IN_BIOTYPE = 'spike-in'
    ERCC_PATTERN = /\AERCC-\d+\z/i
    ENSEMBL_ID_PATTERN = /\AENS[A-Z]*\d+\z/
    EXAMPLE_LIMIT = 3

    def initialize(field_values:, format:)
      @field_values = field_values || {}
      @format = format.to_s
    end

    def call
      errors = []
      valid_checks = []
      resolved = VarIndexSeries.resolve(@field_values, @format)

      unless resolved
        validate_presence_missing(errors, valid_checks)
        return { errors: errors, valid_checks: valid_checks }
      end

      report_field = Rules.var_index_schema_field
      ids = resolved[:values].reject(&:blank?)
      if ids.empty?
        record_failure(errors, valid_checks, field: report_field, message: 'Var index identifiers are missing or empty')
        return { errors: errors, valid_checks: valid_checks }
      end

      record_pass(valid_checks, report_field, "Var index present (#{ids.size} feature identifiers)")
      validate_uniqueness(errors, valid_checks, ids)
      validate_format(errors, valid_checks, ids)

      { errors: errors, valid_checks: valid_checks }
    end

    private

    def validate_presence_missing(errors, valid_checks)
      report_field = Rules.var_index_schema_field
      file_path = Rules.var_index_file_path(@format)
      manifest_key = Rules.var_index_manifest_key
      hint = if @format == 'loom'
               " (Loom file: #{file_path} or anndata_mapping #{manifest_key})"
             else
               " (H5AD file: #{file_path})"
             end
      record_failure(errors, valid_checks, field: report_field, message: "Var index identifiers are missing#{hint}")
    end

    def validate_uniqueness(errors, valid_checks, ids)
      check_id = "#{CHECK_PREFIX}.uniqueness"
      duplicates = ids.group_by(&:itself).select { |_id, group| group.size > 1 }.keys
      if duplicates.any?
        examples = duplicates.first(EXAMPLE_LIMIT).map { |id| "#{id} (#{ids.count(id)} occurrences)" }
        suffix = duplicates.size > EXAMPLE_LIMIT ? '; ...' : ''
        record_failure(
          errors,
          valid_checks,
          field: check_id,
          message: "Var index identifiers must be unique: #{duplicates.size} duplicate identifiers (examples: #{examples.join('; ')}#{suffix})"
        )
        return
      end

      record_pass(valid_checks, check_id, "Var index identifiers are unique (#{ids.size} features)")
    end

    def validate_format(errors, valid_checks, ids)
      check_id = "#{CHECK_PREFIX}.format"
      rows = paired_index_rows(ids)
      issues = rows.filter_map { |row| format_issue(row) }

      if issues.any?
        message = build_failure_message(
          summary: 'Var index identifiers must follow schema format rules (ERCC spike-ins; Ensembl gene_id without version suffix)',
          failed_count: issues.size,
          total_count: rows.size,
          examples: issues
        )
        record_failure(errors, valid_checks, field: check_id, message: message)
        return
      end

      record_pass(valid_checks, check_id, "Var index format rules satisfied for #{ids.size} features")
    end

    def paired_index_rows(ids)
      biotype_path = Rules.field_path(@format, :var, 'feature_biotype')
      biotypes = VarIndexSeries.series_for_path(@field_values, biotype_path)
      if biotypes.length == ids.length
        ids.each_with_index.map do |id, index|
          { index_id: id, feature_biotype: biotypes[index].to_s.strip }
        end
      else
        ids.map { |id| { index_id: id, feature_biotype: nil } }
      end
    end

    def format_issue(row)
      id = row[:index_id].to_s.strip
      biotype = row[:feature_biotype].to_s.strip.presence

      return "#{id.presence || '(blank)'}: identifier must be non-empty" if id.blank?

      if spike_in_row?(biotype, id)
        return "#{id}: spike-in var index must be an ERCC identifier (e.g. ERCC-0003)" unless id.match?(ERCC_PATTERN)

        return nil
      end

      if id.start_with?(Rules.var_index_ensembl_prefix)
        return "#{id}: Ensembl gene_id must not include a version suffix" if id.match?(/\.\d+\z/)
        return "#{id}: invalid Ensembl stable identifier format" unless id.match?(ENSEMBL_ID_PATTERN)
      end

      nil
    end

    def spike_in_row?(biotype, id)
      biotype == SPIKE_IN_BIOTYPE || id.match?(/\AERCC-/i)
    end

    def build_failure_message(summary:, failed_count:, total_count:, examples:)
      noun = failed_count == 1 ? 'feature' : 'features'
      count_label = total_count ? "#{failed_count} of #{total_count}" : failed_count.to_s
      message = "#{summary}: #{count_label} #{noun} failed"
      sample = Array(examples).first(EXAMPLE_LIMIT)
      return message if sample.empty?

      suffix = failed_count > EXAMPLE_LIMIT ? '; ...' : ''
      "#{message} (examples: #{sample.join('; ')}#{suffix})"
    end

    def record_pass(valid_checks, field, message)
      valid_checks << { field: field, status: 'passed', message: message }
    end

    def record_failure(errors, valid_checks, field:, message:)
      errors << { field: field, message: message }
      valid_checks << { field: field, status: 'failed', message: message }
    end
  end
end
