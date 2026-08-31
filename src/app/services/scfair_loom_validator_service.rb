# frozen_string_literal: true

require 'open3'
require 'json'
require 'shellwords'

# scFAIR Cell Metadata Compliance Validator
#
# Validates cell metadata in Loom files against the scFAIR Schema 7.1.0
# requirements, focusing exclusively on cell-level metadata and required
# global attributes.
#
# Reference: https://github.com/scFAIR/scFAIR/blob/main/schema/7.1.0/README.md
#
# ASAP Matrix Orientation:
# ASAP uses a genes x cells matrix orientation (genes as rows, cells as columns).
#   - Cell metadata is in /col_attrs/ (cells are columns)
#   - Global metadata is in /attrs/
#
# Scope of this validator (scFAIR cell metadata compliance):
#   - Required cell metadata fields and their ontology labels
#   - Required global metadata (title, organism_ontology_term_id, organism)
#   - Ontology term format validation for cell metadata fields
#   - Organism-specific requirements for cell metadata
#
# Ontology Versions:
# ASAP applies the structural rules and field requirements from the scFAIR schema,
# but uses its own ontology and reference database versions associated with each
# ASAP version. The specific versions pinned by the upstream schema are NOT enforced.
# This validator checks ontology term FORMAT (PREFIX:ID) but not specific versions.
class ScfairLoomValidatorService
  include ScfairSchemaRules

  SCHEMA_VERSION = Scfair::Rules.schema_version
  ASAP_RUN_CONTAINER = ENV.fetch('ASAP_RUN_CONTAINER').freeze

  VALID_TISSUE_TYPES = Scfair::Rules.enum_field_values('tissue_type')
  VALID_SUSPENSION_TYPES = Scfair::Rules.enum_field_values('suspension_type')
  ALLOWED_SPECIAL_VALUES = Scfair::Rules.allowed_special_values('loom')
  REQUIRED_CELL_METADATA = Scfair::Rules.required_obs_fields
  REQUIRED_GLOBAL_ATTRS = Scfair::Rules.required_uns_fields

  Result = Struct.new(:valid?, :errors, :warnings, :info, :valid_checks, :schema_version, :validated_at, :field_resolutions, keyword_init: true)

  def initialize(loom_path, options = {})
    @loom_path = loom_path
    @project = options[:project]
    @options = options
    @logger = options[:logger] || Rails.logger
    @errors = []
    @warnings = []
    @info = []
    @valid_checks = []
    @field_resolutions = {}
    @metadata_cache = {}

    # Pre-load all latest-version Annot records keyed by name for fast lookups.
    # This avoids N+1 queries when get_metadata_sample / get_global_attr /
    # annot_unique_values are called for each field during validation.
    if @project
      @annots_by_name = @project.annots
        .where(latest_version: true)
        .index_by(&:name)
    else
      @annots_by_name = {}
    end
  end

  def validate
    t_total = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @logger.info("[ScfairLoomValidatorService] Starting validation for: #{@loom_path} (project: #{@project&.id || 'none'})")
    
    unless File.exist?(@loom_path)
      @errors << { field: 'file', message: "File not found: #{@loom_path}" }
      return build_result
    end

    begin
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      gather_file_info
      @logger.info("[Validator TIMING] gather_file_info: #{(Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).round(3)}s")

      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      validate_cell_metadata
      @logger.info("[Validator TIMING] validate_cell_metadata: #{(Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).round(3)}s")

      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      validate_required_global_attributes
      @logger.info("[Validator TIMING] validate_required_global_attributes: #{(Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).round(3)}s")

      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      validate_schema_version
      @logger.info("[Validator TIMING] validate_schema_version: #{(Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).round(3)}s")

      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      validate_ontology_terms
      @logger.info("[Validator TIMING] validate_ontology_terms: #{(Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).round(3)}s")

      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      validate_organism_specific_requirements
      @logger.info("[Validator TIMING] validate_organism_specific_requirements: #{(Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).round(3)}s")

      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      validate_cross_field_constraints
      @logger.info("[Validator TIMING] validate_cross_field_constraints: #{(Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).round(3)}s")

      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      validate_ontology_values_in_database
      @logger.info("[Validator TIMING] validate_ontology_values_in_database: #{(Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).round(3)}s")

      @logger.info("[Validator TIMING] TOTAL validation: #{(Process.clock_gettime(Process::CLOCK_MONOTONIC) - t_total).round(3)}s -- Errors: #{@errors.count}, Warnings: #{@warnings.count}")
    rescue StandardError => e
      @errors << { field: 'validation', message: "Validation failed with error: #{e.message}" }
      @logger.error("[ScfairLoomValidatorService] Validation error: #{e.message}")
      @logger.error(e.backtrace.join("\n"))
    end

    build_result
  end

  private

  def build_result
    Result.new(
      valid?: @errors.empty?,
      errors: @errors,
      warnings: @warnings,
      info: @info,
      valid_checks: @valid_checks,
      schema_version: SCHEMA_VERSION,
      validated_at: Time.current.iso8601,
      field_resolutions: @field_resolutions
    )
  end

  def gather_file_info
    @file_info = extract_file_structure
    @valid_checks << { field: 'file', message: "File readable: #{File.basename(@loom_path)}, Size: #{format_size(File.size(@loom_path))}" }

    if @file_info
      @valid_checks << { field: 'dimensions', message: "Matrix dimensions: #{@file_info[:n_cells]} cells, #{@file_info[:n_genes]} genes" }
    end
  end

  def extract_file_structure
    if @project
      extract_from_annots
    else
      extract_from_loom_file
    end
  end

  # Use Annot records from the project database (fast, no external process)
  def extract_from_annots
    annot_names = @annots_by_name.keys

    if annot_names.empty?
      @warnings << { field: 'file_info', message: 'No annotations found for this project' }
      return nil
    end

    col_attrs = []
    row_attrs = []
    global_attrs = []
    layers = []
    has_matrix = false

    annot_names.each do |name|
      case name
      when %r{\A/col_attrs/(.+)\z}
        col_attrs << $1
      when %r{\A/row_attrs/(.+)\z}
        row_attrs << $1
      when %r{\A/attrs/(.+)\z}
        global_attrs << $1
      when %r{\A/layers/(.+)\z}
        layers << $1
      when '/matrix'
        has_matrix = true
      end
    end

    {
      n_cells: @project.nber_cols,
      n_genes: @project.nber_rows,
      col_attrs: col_attrs,
      row_attrs: row_attrs,
      global_attrs: global_attrs,
      layers: layers,
      has_matrix: has_matrix
    }
  end

  # Use ASAP.jar ListMetadata to read structure directly from the loom file
  def extract_from_loom_file
    output_file = "/tmp/scfair_validation_#{SecureRandom.hex(8)}.json"
    cmd = asap_command('-T', 'ListMetadata', '-f', @loom_path, '-o', output_file)
    _stdout, stderr, status = Open3.capture3(*cmd)

    unless status.success?
      fallback = extract_from_loom_file_h5py
      return fallback if fallback

      @warnings << { field: 'file_info', message: "Could not extract file structure: #{stderr.strip}" }
      return nil
    end

    begin
      raw = JSON.parse(File.read(output_file))
      entries = raw['metadata'] || []

      col_attrs = []
      row_attrs = []
      global_attrs = []
      layers = []
      has_matrix = false
      n_cells = nil
      n_genes = nil

      entries.each do |entry|
        name = entry['name']
        case name
        when %r{\A/col_attrs/(.+)\z}
          col_attrs << $1
          n_cells ||= entry['nber_cols']
        when %r{\A/row_attrs/(.+)\z}
          row_attrs << $1
          n_genes ||= entry['nber_rows']
        when %r{\A/attrs/(.+)\z}
          global_attrs << $1
        when %r{\A/layers/(.+)\z}
          layers << $1
        when '/matrix'
          has_matrix = true
        end
      end

      {
        n_cells: n_cells,
        n_genes: n_genes,
        col_attrs: col_attrs,
        row_attrs: row_attrs,
        global_attrs: global_attrs,
        layers: layers,
        has_matrix: has_matrix
      }
    rescue JSON::ParserError => e
      fallback = extract_from_loom_file_h5py
      return fallback if fallback

      @warnings << { field: 'file_info', message: "Could not parse file structure: #{e.message}" }
      nil
    ensure
      FileUtils.rm_f(output_file)
    end
  end

  def extract_from_loom_file_h5py
    script = <<~PYTHON
      import h5py
      import json
      import sys

      loom_path = sys.argv[1]
      with h5py.File(loom_path, "r") as f:
        col_attrs = list(f["col_attrs"].keys()) if "col_attrs" in f else []
        row_attrs = list(f["row_attrs"].keys()) if "row_attrs" in f else []
        global_attrs = list(f["attrs"].keys()) if "attrs" in f else []
        layers = list(f["layers"].keys()) if "layers" in f else []
        has_matrix = "/matrix" in f

        n_cells = None
        n_genes = None
        if has_matrix:
          m = f["/matrix"]
          if len(m.shape) >= 2:
            n_genes = int(m.shape[0])
            n_cells = int(m.shape[1])

      print(json.dumps({
        "n_cells": n_cells,
        "n_genes": n_genes,
        "col_attrs": col_attrs,
        "row_attrs": row_attrs,
        "global_attrs": global_attrs,
        "layers": layers,
        "has_matrix": has_matrix
      }))
    PYTHON

    stdout, stderr, status = Open3.capture3(
      'docker', 'exec', '-i', ASAP_RUN_CONTAINER, 'python3', '-', @loom_path,
      stdin_data: script
    )
    unless status.success?
      @warnings << { field: 'file_info', message: "Could not extract file structure with fallback: #{stderr.to_s.strip}" }
      return nil
    end

    parsed = JSON.parse(stdout)
    @warnings << { field: 'file_info', message: 'Using h5py structure fallback (ASAP.jar ListMetadata unavailable for this file)' }
    {
      n_cells: parsed['n_cells'],
      n_genes: parsed['n_genes'],
      col_attrs: parsed['col_attrs'] || [],
      row_attrs: parsed['row_attrs'] || [],
      global_attrs: parsed['global_attrs'] || [],
      layers: parsed['layers'] || [],
      has_matrix: parsed['has_matrix'] == true
    }
  rescue JSON::ParserError => e
    @warnings << { field: 'file_info', message: "Could not parse fallback file structure: #{e.message}" }
    nil
  rescue StandardError => e
    @warnings << { field: 'file_info', message: "Could not extract file structure fallback: #{e.message}" }
    nil
  end

  def validate_cell_metadata
    return unless @file_info

    # In ASAP, cells are columns (genes x cells orientation)
    col_attrs = @file_info[:col_attrs] || []

    # Check for CellID (required unique identifier)
    if col_attrs.include?('CellID') || col_attrs.include?('cell_id') || col_attrs.include?('obs_names')
      @valid_checks << presence_check('/col_attrs/CellID', 'passed', 'found')
    else
      @errors << presence_check('/col_attrs/CellID', 'failed', 'missing_cell_id')
    end

    # Check required cell metadata fields
    REQUIRED_CELL_METADATA.each do |field|
      path = "/col_attrs/#{field}"
      if col_attrs.include?(field)
        @valid_checks << presence_check(path, 'passed', 'found')
      else
        # cell_type_ontology_term_id is conditionally required
        if field == 'cell_type_ontology_term_id'
          is_pre_analysis = get_global_attr('is_pre_analysis')
          if is_pre_analysis == true || is_pre_analysis == 'true'
            @valid_checks << presence_check(path, 'skipped', 'skipped_pre_analysis')
            next
          end
        end
        @errors << presence_check(path, 'failed', 'missing')
      end
    end

    # Label/id pair consistency is validated under obs.label_pairs (derived from label_pairs).
    # Validate tissue_type values if present
    if col_attrs.include?('tissue_type')
      validate_categorical_values('tissue_type', VALID_TISSUE_TYPES, '/col_attrs')
    end

    # Validate suspension_type values if present
    if col_attrs.include?('suspension_type')
      validate_categorical_values('suspension_type', VALID_SUSPENSION_TYPES, '/col_attrs')
    end

    # Validate sex_ontology_term_id restricted values
    if col_attrs.include?('sex_ontology_term_id')
      validate_sex_ontology_term_values
    end

    # Check for Visium-specific fields
    assay = get_metadata_sample('/col_attrs/assay_ontology_term_id')
    if assay && is_visium_assay?(assay)
      is_single = get_global_attr('spatial/is_single') || get_global_attr('spatial_is_single')
      if is_single == true || is_single == 'true'
        %w[array_row array_col in_tissue].each do |field|
          path = "/col_attrs/#{field}"
          if col_attrs.include?(field)
            @valid_checks << presence_check(path, 'passed', 'found')
          else
            @errors << presence_check(path, 'failed', 'missing_visium')
          end
        end
      end
    end
  end

  def validate_required_global_attributes
    global_attrs = @file_info&.dig(:global_attrs) || []

    # Check required global attributes
    REQUIRED_GLOBAL_ATTRS.each do |attr|
      path = "/attrs/#{attr}"
      if global_attrs.include?(attr)
        unless attr == 'schema_version'
          @valid_checks << presence_check(path, 'passed', 'found')
        end
      else
        @errors << presence_check(path, 'failed', 'missing')
      end
    end

    # Validate organism_ontology_term_id format
    organism = get_global_attr('organism_ontology_term_id')
    if organism
      organism_path = Scfair::Rules.field_path('loom', :uns, 'organism_ontology_term_id')
      prefixes = Scfair::Rules.ontology_prefixes('organism_ontology_term_id')
      validate_ontology_term_format(organism, organism_path, prefixes)
    end
  end

  def validate_schema_version
    result = Scfair::SchemaVersionEvaluator.call(
      file_version: get_global_attr('schema_version'),
      reference_version: Scfair::Rules.schema_version,
      format: 'loom'
    )
    @errors.concat(result[:errors])
    @warnings.concat(result[:warnings])
    @valid_checks.concat(result[:valid_checks])
  end

  def validate_ontology_terms
    Scfair::Rules.ontology_paths('loom').each do |path, prefixes|
      next if path.start_with?('/attrs/')

      allow_special = ALLOWED_SPECIAL_VALUES.fetch(path, [])
      validate_ontology_field(path, prefixes, allow_special: allow_special)
    end
  end

  def validate_ontology_field(path, valid_prefixes, allow_special: [])
    sample = get_metadata_sample(path)
    return unless sample

    errors_before = @errors.size + @warnings.size
    values = sample.is_a?(Array) ? sample.first(10) : [sample]
    values.compact.each do |value|
      next if value.to_s.strip.empty?

      # Handle multiple terms separated by " || "
      terms = value.to_s.split(' || ')
      terms.each do |term|
        term = term.strip
        next if allow_special.include?(term)
        validate_ontology_term_format(term, path, valid_prefixes)
      end
    end
    errors_after = @errors.size + @warnings.size
    if errors_after == errors_before
      field_name = path.split('/').last
      @valid_checks << Scfair::CheckResult.build(
        check_id: Scfair::Rules::ONTOLOGY_FORMAT_CHECK_ID,
        field: path,
        status: 'passed',
        code: 'valid',
        format: 'loom',
        field_name: field_name
      )
    end
  end

  def validate_ontology_term_format(term, field, valid_prefixes)
    field_name = field.split('/').last.to_s
    format_error = Scfair::Rules.ontology_format_error_message(term, field_name)
    if format_error.present?
      @errors << Scfair::CheckResult.build(
        check_id: Scfair::Rules::ONTOLOGY_FORMAT_CHECK_ID,
        field: field,
        status: 'failed',
        code: 'invalid_obo',
        format: 'loom',
        message: format_error
      )
      return
    end

    prefix = Scfair::Rules.ontology_term_prefix(term)
    return if Scfair::Rules.ontology_term_matches_prefixes?(term, valid_prefixes)

    @errors << Scfair::CheckResult.build(
      check_id: Scfair::Rules::ONTOLOGY_FORMAT_CHECK_ID,
      field: field,
      status: 'failed',
      code: 'unexpected_prefix',
      format: 'loom',
      message: "Unexpected ontology prefix '#{prefix}' for #{field}"
    )
  end

  def validate_organism_specific_requirements
    organism = get_global_attr('organism_ontology_term_id')
    return unless organism

    # Cell metadata (including development_stage) is in /col_attrs/ in ASAP
    case organism
    when 'NCBITaxon:9606' # Human
      @valid_checks << { field: '/attrs/organism_ontology_term_id', message: 'Organism: Homo sapiens -- human-specific requirements checked' }
      validate_ontology_field('/col_attrs/development_stage_ontology_term_id', ['HsapDv', 'UBERON'], allow_special: %w[unknown na])
    when 'NCBITaxon:10090' # Mouse
      @valid_checks << { field: '/attrs/organism_ontology_term_id', message: 'Organism: Mus musculus -- mouse-specific requirements checked' }
      validate_ontology_field('/col_attrs/development_stage_ontology_term_id', ['MmusDv', 'UBERON'], allow_special: %w[unknown na])
    when 'NCBITaxon:6239' # C. elegans
      @valid_checks << { field: '/attrs/organism_ontology_term_id', message: 'Organism: C. elegans -- C. elegans-specific requirements checked' }
      validate_ontology_field('/col_attrs/development_stage_ontology_term_id', ['WBls'], allow_special: %w[unknown na])
    when 'NCBITaxon:7955' # Zebrafish
      @valid_checks << { field: '/attrs/organism_ontology_term_id', message: 'Organism: Danio rerio -- zebrafish-specific requirements checked' }
      validate_ontology_field('/col_attrs/development_stage_ontology_term_id', ['ZFS', 'UBERON'], allow_special: %w[unknown na])
    when 'NCBITaxon:7227' # Drosophila
      @valid_checks << { field: '/attrs/organism_ontology_term_id', message: 'Organism: Drosophila melanogaster -- fly-specific requirements checked' }
      validate_ontology_field('/col_attrs/development_stage_ontology_term_id', ['FBdv', 'UBERON'], allow_special: %w[unknown na])
    end
  end

  # Cross-field constraint checks using the shared ScfairSchemaRules module.
  # These rules enforce dependencies between fields (e.g. assay determines
  # tissue_type="cell line" forces several fields to "na").
  def validate_cross_field_constraints
    return unless @file_info

    col_attrs = @file_info[:col_attrs] || []

    # Read the actual values from the LOOM (first unique value per field).
    # For cell-level fields, get_metadata_sample returns the first N values;
    # we collect all unique values to check.
    organism = get_global_attr('organism_ontology_term_id')

    assay_sample = get_metadata_sample('/col_attrs/assay_ontology_term_id')
    assay_values = assay_sample.is_a?(Array) ? assay_sample.uniq : [assay_sample].compact

    tissue_type_sample = get_metadata_sample('/col_attrs/tissue_type')
    tissue_type_values = tissue_type_sample.is_a?(Array) ? tissue_type_sample.uniq : [tissue_type_sample].compact

    suspension_sample = get_metadata_sample('/col_attrs/suspension_type')
    suspension_values = suspension_sample.is_a?(Array) ? suspension_sample.uniq : [suspension_sample].compact

    ethnicity_sample = get_metadata_sample('/col_attrs/self_reported_ethnicity_ontology_term_id')
    ethnicity_values = ethnicity_sample.is_a?(Array) ? ethnicity_sample.uniq : [ethnicity_sample].compact

    sex_sample = get_metadata_sample('/col_attrs/sex_ontology_term_id')
    sex_values = sex_sample.is_a?(Array) ? sex_sample.uniq : [sex_sample].compact

    dev_stage_sample = get_metadata_sample('/col_attrs/development_stage_ontology_term_id')
    dev_stage_values = dev_stage_sample.is_a?(Array) ? dev_stage_sample.uniq : [dev_stage_sample].compact

    donor_sample = get_metadata_sample('/col_attrs/donor_id')
    donor_values = donor_sample.is_a?(Array) ? donor_sample.uniq : [donor_sample].compact

    tissue_sample = get_metadata_sample('/col_attrs/tissue_ontology_term_id')
    tissue_values = tissue_sample.is_a?(Array) ? tissue_sample.uniq : [tissue_sample].compact

    # Check all combinations of unique values for violations.
    # For most datasets, each field has a single unique value (uniform metadata),
    # so we check each unique value against the constraints.
    assay_id = assay_values.first
    tissue_type = tissue_type_values.first

    # Check each unique suspension_type value against the assay constraint
    suspension_values.each do |susp|
      violations = check_cross_field_constraints(
        organism_tax_id: organism,
        assay_term_id: assay_id,
        tissue_type: tissue_type,
        suspension_type: susp,
        ethnicity_term_id: nil,
        sex_term_id: nil,
        dev_stage_term_id: nil,
        donor_id_val: nil,
        tissue_term_id: nil
      )
      violations.each do |v|
        if v[:severity] == :error
          @errors << { field: v[:field], message: v[:message] }
        else
          @warnings << { field: v[:field], message: v[:message] }
        end
      end
    end

    # Check ethnicity, sex, dev_stage, donor_id, tissue constraints
    # (organism-dependent and tissue_type-dependent rules)
    ethnicity_values.each do |eth|
      sex_values.each do |sx|
        dev_stage_values.each do |ds|
          donor_values.each do |dn|
            tissue_values.each do |ts|
              violations = check_cross_field_constraints(
                organism_tax_id: organism,
                assay_term_id: nil,
                tissue_type: tissue_type,
                suspension_type: nil,
                ethnicity_term_id: eth,
                sex_term_id: sx,
                dev_stage_term_id: ds,
                donor_id_val: dn,
                tissue_term_id: ts
              )
              violations.each do |v|
                if v[:severity] == :error
                  @errors << { field: v[:field], message: v[:message] }
                else
                  @warnings << { field: v[:field], message: v[:message] }
                end
              end
            end
          end
        end
      end
    end

    # Deduplicate: the cartesian product above may produce duplicate messages
    @errors.uniq!
    @warnings.uniq!
  end

  # Validate that all ontology term values present in the metadata actually
  # exist in the database and belong to ontologies authorised for their field
  # and for the project's organism.  Only runs when @project is available
  # (so that Annot records and organism info can be used).
  def validate_ontology_values_in_database
    return unless @project

    organism = @project.organism
    tax_id_str = organism&.tax_id&.to_s

    # Load OntologyTermType records that define which ontologies are valid per field
    otts = OntologyTermType.where.not(field_group_id: [nil, ''])
                           .to_a
    return if otts.empty?

    co_id_to_tag = CellOntology.pluck(:id, :tag).to_h
    # Pre-load CellOntology id/tag/tax_ids for filtering
    all_co_ids = otts.flat_map(&:cell_ontology_ids_list).uniq
    ontologies = CellOntology.where(id: all_co_ids).index_by(&:id)

    otts.each do |ott|
      term_path = ott.term_path
      next if term_path.blank?

      # Build field group info for label_path
      label_path = ott.respond_to?(:label_path) ? ott.label_path : nil
      label_path = nil if label_path.blank?
      fg = ott.to_field_group(co_id_to_tag)
      label_path ||= fg[:label_path]

      # Determine which ontology IDs are valid for this field + organism
      valid_co_ids = ott.cell_ontology_ids_list.select do |co_id|
        co = ontologies[co_id]
        next false unless co
        co.tax_ids.blank? || (tax_id_str.present? && co.tax_ids.to_s.split(',').map(&:strip).include?(tax_id_str))
      end

      # Collect allowed free-text values (e.g. "unknown", "na")
      allowed_free_text = Set.new(ott.free_text_entries.map { |e| e.is_a?(Hash) ? e['value'].to_s : e.to_s })
      schema_specials = ALLOWED_SPECIAL_VALUES[term_path]
      allowed_free_text.merge(schema_specials) if schema_specials

      # Fields with fixed valid-values list (e.g. tissue_type, suspension_type)
      valid_values = fg[:term_valid_values]
      if valid_values.present?
        unique_values = annot_unique_values(term_path)
        if unique_values.present?
          valid_set = valid_values.map(&:downcase).to_set
          resolution = unique_values.index_with { |v| valid_set.include?(v.downcase) }
          @field_resolutions[term_path] = resolution
          invalid = resolution.count { |_v, ok| ok == false }
          field_name = term_path.split('/').last
          if invalid > 0
            @errors << { field: term_path, message: "#{invalid} of #{unique_values.size} #{unique_values.size == 1 ? 'value' : 'values'} in '#{field_name}' not valid (allowed: #{valid_values.join(', ')})" }
          else
            n = unique_values.size
            @valid_checks << { field: term_path, message: "#{n <= 2 ? 'The' : 'All'} #{n} #{n == 1 ? 'value' : 'values'} in '#{field_name}' #{n == 1 ? 'is' : 'are'} valid" }
          end
        end
        next
      end

      # Ontology-based fields: skip if no ontology config
      next if valid_co_ids.empty?

      scope = CellOntologyTerm.with_active_cell_ontology.where(original: true, cell_ontology_id: valid_co_ids)
      valid_tags = valid_co_ids.filter_map { |cid| ontologies[cid]&.tag }

      # --- Resolve term path (identifiers) ---
      unique_values = annot_unique_values(term_path)
      if unique_values.present?
        all_terms = Set.new
        unique_values.each { |val| val.to_s.split(' || ').each { |t| all_terms << t.strip } }
        all_terms.reject!(&:blank?)

        ontology_terms = all_terms.reject { |t| allowed_free_text.include?(t) }
        existing_ids = ontology_terms.any? ? scope.where(identifier: ontology_terms.to_a).pluck(:identifier).to_set : Set.new
        known = existing_ids | allowed_free_text

        resolution = unique_values.index_with do |v|
          parts = v.to_s.split(' || ').map(&:strip).reject(&:blank?)
          parts.all? { |p| known.include?(p) }
        end
        @field_resolutions[term_path] = resolution

        unresolved_count = resolution.count { |_v, ok| ok == false }
        field_name = term_path.split('/').last
        if unresolved_count > 0
          missing = ontology_terms.reject { |t| existing_ids.include?(t) }
          @errors << {
            field: term_path,
            message: "#{unresolved_count} of #{unique_values.size} #{field_name} #{unique_values.size == 1 ? 'identifier' : 'identifiers'} not found in authorised ontologies (#{valid_tags.join(', ')}): #{missing.first(5).join(', ')}#{missing.size > 5 ? ', ...' : ''}"
          }
        else
          n = unique_values.size
          @valid_checks << { field: term_path, message: "#{n <= 2 ? 'The' : 'All'} #{n} #{field_name} #{n == 1 ? 'identifier' : 'identifiers'} found in authorised ontologies" }
        end
      end

      # --- Resolve label path (names) ---
      next unless label_path.present?

      label_values = annot_unique_values(label_path)
      next unless label_values.present?

      all_names = Set.new
      label_values.each { |val| val.to_s.split(' || ').each { |t| all_names << t.strip } }
      all_names.reject!(&:blank?)

      ontology_names = all_names.reject { |t| allowed_free_text.include?(t) }
      exact_names = Set.new(allowed_free_text)
      mappable_names = Set.new

      if ontology_names.any?
        # Exact match (case-insensitive)
        lower_map = {}
        ontology_names.each { |n| lower_map[n.downcase] = n }
        scope.where('LOWER(cell_ontology_terms.name) IN (?)', lower_map.keys)
             .pluck('cell_ontology_terms.name').each { |n| exact_names << lower_map[n.downcase] if lower_map[n.downcase] }

        # Retry unresolved with underscores replaced by spaces
        remaining = ontology_names.reject { |n| exact_names.include?(n) }
        if remaining.any?
          space_map = {}
          remaining.select { |n| n.include?('_') }.each { |n| space_map[n.tr('_', ' ').downcase] = n }
          if space_map.any?
            scope.where('LOWER(cell_ontology_terms.name) IN (?)', space_map.keys)
                 .pluck('cell_ontology_terms.name').each { |n| mappable_names << space_map[n.downcase] if space_map[n.downcase] }
          end
        end
      end

      # Resolution: true = exact match, 'mappable' = matched after transformation, false = unresolved
      resolution = label_values.index_with do |v|
        parts = v.to_s.split(' || ').map(&:strip).reject(&:blank?)
        if parts.all? { |p| exact_names.include?(p) }
          true
        elsif parts.all? { |p| exact_names.include?(p) || mappable_names.include?(p) }
          'mappable'
        else
          false
        end
      end
      @field_resolutions[label_path] = resolution

      unresolved_count = resolution.count { |_v, ok| ok == false }
      mappable_count = resolution.count { |_v, ok| ok == 'mappable' }
      label_name = label_path.split('/').last
      if unresolved_count > 0
        missing_names = ontology_names.reject { |t| exact_names.include?(t) || mappable_names.include?(t) }
        @errors << {
          field: label_path,
          message: "#{unresolved_count} of #{label_values.size} #{label_name} #{label_values.size == 1 ? 'name' : 'names'} not found in authorised ontologies (#{valid_tags.join(', ')}): #{missing_names.first(5).join(', ')}#{missing_names.size > 5 ? ', ...' : ''}"
        }
      end
      if mappable_count > 0
        mappable_list = ontology_names.select { |t| mappable_names.include?(t) }
        @warnings << {
          field: label_path,
          message: "#{mappable_count} #{label_name} #{mappable_count == 1 ? 'name' : 'names'} can be auto-mapped to correct ontology #{mappable_count == 1 ? 'label' : 'labels'}: #{mappable_list.first(5).join(', ')}#{mappable_list.size > 5 ? ', ...' : ''}"
        }
      end
      if unresolved_count == 0 && mappable_count == 0
        @valid_checks << { field: label_path, message: "#{label_values.size <= 2 ? 'The' : 'All'} #{label_values.size} #{label_name} #{label_values.size == 1 ? 'name' : 'names'} found in authorised ontologies" }
      elsif unresolved_count == 0 && mappable_count > 0
        exact_count = label_values.size - mappable_count
        @valid_checks << { field: label_path, message: "#{exact_count} of #{label_values.size} #{label_name} #{label_values.size == 1 ? 'name' : 'names'} found in authorised ontologies" }
      end
    end
  end

  def validate_categorical_values(field, valid_values, prefix)
    sample = get_metadata_sample("#{prefix}/#{field}")
    return unless sample

    values = sample.is_a?(Array) ? sample : [sample]
    invalid_values = values.uniq.reject { |v| valid_values.include?(v) }

    if invalid_values.any?
      @errors << {
        field: "#{prefix}/#{field}",
        message: "Invalid values found: #{invalid_values.first(3).join(', ')}. Must be one of: #{valid_values.join(', ')}"
      }
    else
      @valid_checks << { field: "#{prefix}/#{field}", message: "All '#{field}' values are valid (#{valid_values.join(', ')})" }
    end
  end

  def validate_sex_ontology_term_values
    sample = get_metadata_sample('/col_attrs/sex_ontology_term_id')
    return unless sample

    values = sample.is_a?(Array) ? sample : [sample]
    allowed_special = ALLOWED_SPECIAL_VALUES['/col_attrs/sex_ontology_term_id'] || []

    invalid = values.uniq.reject { |v| VALID_SEX_TERMS.key?(v) || allowed_special.include?(v) }

    if invalid.any?
      allowed_desc = VALID_SEX_TERMS.map { |id, name| "#{id} (#{name})" }.join(', ')
      @errors << {
        field: '/col_attrs/sex_ontology_term_id',
        message: "Invalid sex_ontology_term_id: #{invalid.first(5).join(', ')}. Must be one of: #{allowed_desc}, unknown, or na."
      }
    else
      @valid_checks << {
        field: '/col_attrs/sex_ontology_term_id',
        message: "All sex_ontology_term_id values are from the allowed set (#{VALID_SEX_TERMS.values.join(', ')}, unknown, na)"
      }
    end
  end

  # Helper methods

  # Get unique values for a field path from the Annot record's list_cat_json.
  # Returns an array of unique string values, or nil if not available.
  # Uses the pre-loaded @annots_by_name cache for O(1) lookup.
  def annot_unique_values(field_path)
    return nil unless @project

    annot = @annots_by_name[field_path]
    return nil unless annot

    if annot.list_cat_json.present?
      begin
        vals = JSON.parse(annot.list_cat_json)
        return vals if vals.is_a?(Array) && vals.any?
      rescue JSON::ParserError
        # fall through
      end
    end

    if annot.categories_json.present?
      begin
        cats = JSON.parse(annot.categories_json)
        return cats.keys if cats.is_a?(Hash) && cats.any?
      rescue JSON::ParserError
        # fall through
      end
    end

    nil
  end

  def is_visium_assay?(assay_term)
    return false unless assay_term

    assay_term.to_s.split(' || ').map(&:strip).any? do |term|
      Scfair::SpatialAssayHelper.visium_assay?(term)
    end
  end

  def get_global_attr(key)
    cache_key = "global:#{key}"
    return @metadata_cache[cache_key] if @metadata_cache.key?(cache_key)

    @metadata_cache[cache_key] = if @project
      # Read from Annot records -- no Docker/Java overhead
      annot = @annots_by_name["/attrs/#{key}"]
      extract_single_value_from_annot(annot)
    else
      # External process: Docker+Java (slow, only used without @project)
      begin
        cmd = asap_command('-T', 'ExtractGlobalAttr', '-attr', key, '-loom', @loom_path)
        stdout, _stderr, status = Open3.capture3(*cmd)
        if status.success?
          value = stdout.strip
          value.empty? ? nil : value
        end
      rescue StandardError
        nil
      end
    end
  end

  def get_metadata_sample(path, limit: 10)
    cache_key = path
    return @metadata_cache[cache_key] if @metadata_cache.key?(cache_key)

    @metadata_cache[cache_key] = if @project
      # Read unique values from Annot records -- no Docker/Java overhead.
      # Returns all unique values (more thorough than a random sample).
      vals = annot_unique_values(path)
      vals&.first(limit)
    else
      # External process: Docker+Java (slow, only used without @project)
      begin
        cmd = asap_command('-T', 'ExtractMetadata', '-meta', path, '-loom', @loom_path)
        stdout, _stderr, status = Open3.capture3(*cmd)
        if status.success?
          result = JSON.parse(stdout)
          values = result['values']
          values.is_a?(Array) ? values.first(limit) : values
        end
      rescue StandardError
        nil
      end
    end
  end

  # Extract a single value from an Annot record (for global attributes).
  def extract_single_value_from_annot(annot)
    return nil unless annot

    if annot.list_cat_json.present?
      vals = JSON.parse(annot.list_cat_json) rescue nil
      return vals.first if vals.is_a?(Array) && vals.any?
    end

    if annot.categories_json.present?
      cats = JSON.parse(annot.categories_json) rescue nil
      return cats.keys.first if cats.is_a?(Hash) && cats.any?
    end

    nil
  end

  def asap_command(*args)
    ['docker', 'exec', ASAP_RUN_CONTAINER, 'java', '-jar', '/srv/ASAP.jar'] + args
  end

  def presence_check(field, status, code)
    Scfair::CheckResult.presence(
      field: field,
      format: 'loom',
      status: status,
      code: code,
      path: field
    )
  end

  def format_size(bytes)
    units = ['B', 'KB', 'MB', 'GB', 'TB']
    unit_index = 0
    size = bytes.to_f
    
    while size >= 1024 && unit_index < units.length - 1
      size /= 1024
      unit_index += 1
    end
    
    "#{size.round(2)} #{units[unit_index]}"
  end
end
