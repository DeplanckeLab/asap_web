# frozen_string_literal: true

module Scfair
  # Cross-field checks between var gene metadata, var index, and uns organism / ensembl_release.
  class VarCrossFieldValidator
    CHECK_PREFIX = 'var.cross_field'
    SERIES_SUFFIX = '#series'
    INDEX_FIELD = '_index'
    SPIKE_IN_BIOTYPE = 'spike-in'
    GENE_BIOTYPE = 'gene'
    EXAMPLE_LIMIT = 3

    def initialize(field_values:, format:, lookup: EnsemblReferenceLookup.new)
      @field_values = field_values || {}
      @format = format.to_s
      @lookup = lookup
      @reference_policy = FeatureReferenceTaxonPolicy.new
    end

    def call
      errors = []
      valid_checks = []

      organism_term = first_uns_value('organism_ontology_term_id')
      release = parse_ensembl_release

      validate_feature_reference(errors, valid_checks, organism_term)
      validate_feature_name_index(errors, valid_checks)
      validate_var_index_release(errors, valid_checks, organism_term, release)

      { errors: errors, valid_checks: valid_checks }
    end

    private

    def validate_feature_reference(errors, valid_checks, organism_term)
      check_id = "#{CHECK_PREFIX}.feature_reference"
      rows = paired_var_rows(%w[feature_biotype feature_reference])
      if rows.empty?
        validate_feature_reference_aggregate(errors, valid_checks, check_id, organism_term)
        return
      end

      issues = rows.filter_map { |row| feature_reference_issue(row, organism_term) }

      if issues.any?
        message = build_failure_message(
          summary: 'feature_reference must use an allowed NCBITaxon lineage for each feature biotype',
          failed_count: issues.size,
          total_count: rows.size,
          examples: issues
        )
        record_failure(errors, valid_checks, check_id:, message:)
        return
      end

      record_pass(valid_checks, check_id, "feature_reference values match schema reference taxa (#{rows.size} features checked)")
    end

    def feature_reference_issue(row, organism_term)
      biotype = row['feature_biotype'].to_s
      reference = row['feature_reference'].to_s
      return nil if reference.blank?

      unless @lookup.allowed_feature_reference?(reference, biotype:)
        return @reference_policy.rejection_message(reference, biotype:) ||
               "#{reference}: not an allowed feature_reference for feature_biotype #{biotype.inspect}"
      end

      if biotype == GENE_BIOTYPE && organism_term.present? && reference != organism_term
        return "#{reference}: gene feature_reference must match organism_ontology_term_id (#{organism_term})"
      end

      nil
    end

    def validate_feature_reference_aggregate(errors, valid_checks, check_id, organism_term)
      references = values_for_var('feature_reference')
      biotypes = values_for_var('feature_biotype')

      if references.empty?
        record_skip(valid_checks, check_id, 'feature_reference not available for cross-field check')
        return
      end

      unexpected = references.reject { |reference| @reference_policy.allowed_gene_reference?(reference) || reference == EnsemblReferenceLookup::SPIKE_IN_TAXON }
      if unexpected.any?
        message = "feature_reference must use an allowed NCBITaxon lineage (#{Rules.feature_reference_policy_requirement_text}; unexpected: #{unexpected.first(3).join(', ')})"
        record_failure(errors, valid_checks, check_id:, message:)
        return
      end

      if organism_term.present? && biotypes.include?(GENE_BIOTYPE) && references.include?(organism_term) == false
        record_failure(errors, valid_checks, check_id:, message: "feature_reference must include #{organism_term} when feature_biotype contains gene")
        return
      end

      if biotypes.include?(SPIKE_IN_BIOTYPE) && references.exclude?(EnsemblReferenceLookup::SPIKE_IN_TAXON)
        record_failure(errors, valid_checks, check_id:, message: "feature_reference must include #{EnsemblReferenceLookup::SPIKE_IN_TAXON} when feature_biotype contains spike-in")
        return
      end

      record_pass(valid_checks, check_id, 'feature_reference values match allowed NCBITaxon lineages')
    end

    def validate_feature_name_index(errors, valid_checks)
      check_id = "#{CHECK_PREFIX}.feature_name.index"
      rows = paired_var_rows(%w[feature_biotype feature_reference feature_name] + [INDEX_FIELD])
      if rows.empty?
        record_skip(valid_checks, check_id, 'Row-level feature_name and var index series not available')
        return
      end

      release = parse_ensembl_release
      if release.blank?
        record_skip(valid_checks, check_id, 'ensembl_release not set; cannot verify feature_name against gene reference')
        return
      end

      preload_release_gene_names(rows, release)

      issues = rows.filter_map { |row| feature_name_index_issue(row, release:) }

      if issues.any?
        message = build_failure_message(
          summary: 'feature_name must match the gene reference for var index (gene_name when assigned, otherwise the index identifier)',
          failed_count: issues.size,
          total_count: rows.size,
          examples: issues
        )
        record_failure(errors, valid_checks, check_id:, message:)
        return
      end

      record_pass(valid_checks, check_id, "feature_name values match var index per schema (#{rows.size} features checked)")
    end

    def feature_name_index_issue(row, release: nil)
      biotype = row['feature_biotype'].to_s
      reference = row['feature_reference'].to_s
      name = row['feature_name'].to_s
      index_id = row[INDEX_FIELD].to_s
      return nil if name.blank?

      case biotype
      when SPIKE_IN_BIOTYPE
        return "#{index_id.presence || name}: spike-in var index must be an ERCC identifier" unless index_id.start_with?('ERCC-')
        return "#{index_id}: spike-in feature_reference must be #{EnsemblReferenceLookup::SPIKE_IN_TAXON}" unless reference == EnsemblReferenceLookup::SPIKE_IN_TAXON

        expected = @lookup.spike_in_feature_name_for_index(index_id)
        return "#{index_id}: feature_name must be #{expected.inspect} (got #{name.inspect})" unless name == expected

        nil
      when GENE_BIOTYPE
        return "#{name}: gene row requires var index identifier" if index_id.blank?
        return "#{index_id}: feature_reference is required to resolve expected gene_name" if reference.blank?

        expected = @lookup.expected_feature_name(
          feature_reference: reference,
          index_id: index_id,
          biotype: biotype,
          release: release
        )
        return "#{index_id}: feature_name must be #{expected.inspect} (got #{name.inspect})" unless name == expected

        nil
      else
        return "#{name}: feature_biotype #{biotype.inspect} is not gene or spike-in" if biotype.present?

        nil
      end
    end

    def preload_release_gene_names(rows, release)
      return if release.blank?

      gene_ids = rows.filter_map do |row|
        next unless row['feature_biotype'].to_s == GENE_BIOTYPE

        row[INDEX_FIELD].to_s.presence
      end
      return if gene_ids.empty?

      reference = rows.map { |row| row['feature_reference'].to_s }.find(&:present?)
      reference ||= first_uns_value('organism_ontology_term_id')
      return if reference.blank?

      @lookup.preload_release_gene_names(
        feature_reference: reference,
        release: release,
        ensembl_ids: gene_ids
      )
    end

    def validate_var_index_release(errors, valid_checks, organism_term, release)
      check_id = "#{CHECK_PREFIX}.index.release"

      if release.blank?
        record_skip(valid_checks, check_id, 'ensembl_release not set; cannot verify var index gene identifiers against the annotation release')
        return
      end

      tax_id = extract_tax_id(organism_term)
      remote_organism = tax_id.present? ? @lookup.remote_organism_for_tax_id(tax_id) : nil
      unless remote_organism
        record_skip(valid_checks, check_id, 'ASAP reference genes unavailable for this organism')
        return
      end

      ids = var_index_ids
      if ids.empty?
        record_skip(valid_checks, check_id, 'Var index identifiers not available for cross-field check')
        return
      end

      gene_ids = ids.reject { |feature_id| feature_id.start_with?('ERCC-') }
      if gene_ids.empty?
        record_skip(valid_checks, check_id, 'No gene var index identifiers available to verify')
        return
      end

      issues = []
      gene_ids.each do |feature_id|
        ensembl_id = @lookup.normalize_ensembl_id(feature_id)
        status = @lookup.gene_status_at_release(
          organism_id: remote_organism.id,
          release: release,
          ensembl_id: ensembl_id
        )
        case status
        when :not_found
          issues << "#{feature_id} (not in ASAP genes)"
        when :too_new, :deprecated
          issues << "#{feature_id} (not present at Ensembl release #{release})"
        when :unavailable
          record_skip(valid_checks, check_id, 'ASAP reference gene database unavailable')
          return
        end
      end

      if issues.any?
        message = build_failure_message(
          summary: "var index gene identifiers must exist for the dataset organism at ensembl_release #{release}",
          failed_count: issues.size,
          total_count: gene_ids.size,
          examples: issues
        )
        record_failure(errors, valid_checks, check_id:, message:)
        return
      end

      record_pass(valid_checks, check_id, "Var index identifiers are known for the organism at Ensembl release #{release} (#{gene_ids.size} features checked)")
    end

    def paired_var_rows(fields)
      series = fields.map { |field| [field, series_values(field)] }.to_h
      return [] if series.values.any?(&:empty?)

      length = series.values.map(&:length).min
      (0...length).map do |index|
        fields.index_with { |field| series[field][index].to_s.strip }
      end
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

    def var_index_ids
      Array(VarIndexSeries.resolve(@field_values, @format)&.dig(:values)).map(&:to_s).map(&:strip).reject(&:blank?)
    end

    def series_values(field_name)
      key = if field_name == INDEX_FIELD
              var_path(INDEX_FIELD) + SERIES_SUFFIX
            else
              "#{var_path(field_name)}#{SERIES_SUFFIX}"
            end
      Array(@field_values[key] || @field_values[key.to_sym]).map(&:to_s)
    end

    def values_for_var(field_name)
      Array(@field_values[var_path(field_name)] || @field_values[var_path(field_name).to_sym])
        .map(&:to_s).map(&:strip).reject(&:blank?)
    end

    def parse_ensembl_release
      raw = first_uns_value('ensembl_release')
      return nil if raw.blank?
      return nil unless raw.match?(/\A\d+\z/)

      raw.to_i
    end

    def first_uns_value(name)
      path = Rules.field_path(@format, :uns, name)
      Array(@field_values[path] || @field_values[path.to_sym]).first.to_s.strip.presence
    end

    def extract_tax_id(term_id)
      match = term_id.to_s.match(/\ANCBITaxon:(\d+)\z/)
      return nil unless match

      match[1].to_i
    end

    def var_path(field_name)
      Rules.field_path(@format, :var, field_name)
    end

    def record_pass(valid_checks, field, message)
      valid_checks << { field: field, status: 'passed', message: message }
    end

    def record_skip(valid_checks, field, message)
      valid_checks << { field: field, status: 'skipped', message: message }
    end

    def record_failure(errors, valid_checks, check_id:, message:)
      errors << { field: check_id, message: message }
      valid_checks << { field: check_id, status: 'failed', message: message }
    end
  end
end
