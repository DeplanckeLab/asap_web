# frozen_string_literal: true

require 'open3'
require 'json'
require 'shellwords'

# scFAIR Cell Metadata Compliance Validator
#
# Validates cell metadata in Loom files against the CELLxGENE Schema 7.1.0
# requirements, focusing exclusively on cell-level metadata and required
# global attributes.
#
# Reference: https://github.com/chanzuckerberg/single-cell-curation/blob/main/schema/7.1.0/schema.md
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
# ASAP applies the structural rules and field requirements from CELLxGENE schema,
# but uses its own ontology and reference database versions associated with each
# ASAP version. The specific versions pinned by CELLxGENE are NOT enforced.
# This validator checks ontology term FORMAT (PREFIX:ID) but not specific versions.
class CxgLoomValidatorService
  SCHEMA_VERSION = '7.1.0'
  ASAP_RUN_CONTAINER = ENV.fetch('ASAP_RUN_CONTAINER', 'asap_run').freeze

  # Valid ontology prefixes for different field types
  VALID_ONTOLOGY_PREFIXES = {
    assay: ['EFO'],
    cell_type: ['CL', 'WBbt', 'ZFA', 'FBbt'],
    development_stage: ['HsapDv', 'MmusDv', 'WBls', 'ZFS', 'FBdv', 'UBERON'],
    disease: ['MONDO', 'PATO'],
    sex: ['PATO'],
    tissue: ['UBERON', 'CVCL', 'WBbt', 'ZFA', 'FBbt'],
    ethnicity: ['HANCESTRO', 'AfPO'],
    organism: ['NCBITaxon']
  }.freeze

  # Valid values for enumerated fields
  VALID_TISSUE_TYPES = ['tissue', 'organoid', 'cell line', 'primary cell culture'].freeze
  VALID_SUSPENSION_TYPES = ['cell', 'nucleus', 'na'].freeze
  # Required cell metadata fields (curator must annotate)
  REQUIRED_CELL_METADATA = %w[
    assay_ontology_term_id
    cell_type_ontology_term_id
    development_stage_ontology_term_id
    disease_ontology_term_id
    donor_id
    is_primary_data
    self_reported_ethnicity_ontology_term_id
    sex_ontology_term_id
    suspension_type
    tissue_ontology_term_id
    tissue_type
  ].freeze

  # Required global attributes
  REQUIRED_GLOBAL_ATTRS = %w[title organism_ontology_term_id].freeze

  # Ontology label fields: these are the human-readable names corresponding to *_ontology_term_id fields.
  # They are required alongside their _ontology_term_id counterpart.
  ONTOLOGY_LABEL_CELL_METADATA = %w[
    assay cell_type development_stage disease
    self_reported_ethnicity sex tissue
  ].freeze

  # Ontology label for global attrs
  ONTOLOGY_LABEL_GLOBAL_ATTRS = %w[organism].freeze

  Result = Struct.new(:valid?, :errors, :warnings, :info, :schema_version, :validated_at, keyword_init: true)

  def initialize(loom_path, options = {})
    @loom_path = loom_path
    @project = options[:project]
    @options = options
    @logger = options[:logger] || Rails.logger
    @errors = []
    @warnings = []
    @info = []
    @metadata_cache = {}
  end

  def validate
    @logger.info("[CxgLoomValidatorService] Starting validation for: #{@loom_path}")
    
    unless File.exist?(@loom_path)
      @errors << { field: 'file', message: "File not found: #{@loom_path}" }
      return build_result
    end

    begin
      # Gather file structure info
      gather_file_info

      # scFAIR cell metadata compliance checks only
      validate_cell_metadata
      validate_required_global_attributes
      validate_ontology_terms
      validate_organism_specific_requirements

      @logger.info("[CxgLoomValidatorService] scFAIR cell metadata compliance complete. Errors: #{@errors.count}, Warnings: #{@warnings.count}")
    rescue StandardError => e
      @errors << { field: 'validation', message: "Validation failed with error: #{e.message}" }
      @logger.error("[CxgLoomValidatorService] Validation error: #{e.message}")
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
      schema_version: SCHEMA_VERSION,
      validated_at: Time.current.iso8601
    )
  end

  def gather_file_info
    @file_info = extract_file_structure
    @info << { field: 'file', message: "File: #{File.basename(@loom_path)}, Size: #{format_size(File.size(@loom_path))}" }
    
    if @file_info
      @info << { field: 'dimensions', message: "Cells: #{@file_info[:n_cells]}, Genes: #{@file_info[:n_genes]}" }
      @info << { field: 'col_attrs', message: "Cell metadata fields: #{@file_info[:col_attrs]&.join(', ') || 'none'}" }
      @info << { field: 'global_attrs', message: "Global attributes: #{@file_info[:global_attrs]&.join(', ') || 'none'}" }
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
    annot_names = @project.annots.pluck(:name).compact

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
    output_file = "/tmp/cxg_validation_#{SecureRandom.hex(8)}.json"
    cmd = asap_command('-T', 'ListMetadata', '-f', @loom_path, '-o', output_file)
    _stdout, stderr, status = Open3.capture3(*cmd)

    unless status.success?
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
      @warnings << { field: 'file_info', message: "Could not parse file structure: #{e.message}" }
      nil
    ensure
      FileUtils.rm_f(output_file)
    end
  end

  def validate_cell_metadata
    return unless @file_info

    # In ASAP, cells are columns (genes x cells orientation)
    col_attrs = @file_info[:col_attrs] || []

    # Check for CellID (required unique identifier)
    unless col_attrs.include?('CellID') || col_attrs.include?('cell_id') || col_attrs.include?('obs_names')
      @errors << { field: '/col_attrs/CellID', message: 'Cell identifiers not found. REQUIRED: unique cell identifiers in /col_attrs/CellID' }
    end

    # Check required cell metadata fields
    REQUIRED_CELL_METADATA.each do |field|
      unless col_attrs.include?(field)
        # cell_type_ontology_term_id is conditionally required
        if field == 'cell_type_ontology_term_id'
          is_pre_analysis = get_global_attr('is_pre_analysis')
          if is_pre_analysis == true || is_pre_analysis == 'true'
            @info << { field: "/col_attrs/#{field}", message: 'Skipped (pre-analysis dataset)' }
            next
          end
        end
        @errors << { field: "/col_attrs/#{field}", message: "REQUIRED field '#{field}' not found in cell metadata" }
      end
    end

    # Check for ontology label fields (required alongside their _ontology_term_id counterpart)
    ONTOLOGY_LABEL_CELL_METADATA.each do |field|
      next if col_attrs.include?(field)

      # cell_type follows the same conditional rule as cell_type_ontology_term_id
      if field == 'cell_type'
        is_pre_analysis = get_global_attr('is_pre_analysis')
        next if is_pre_analysis == true || is_pre_analysis == 'true'
      end

      ontology_field = "#{field}_ontology_term_id"
      @errors << { field: "/col_attrs/#{field}", message: "REQUIRED field '#{field}' not found. This is the human-readable label for '#{ontology_field}'." }
    end

    # Validate tissue_type values if present
    if col_attrs.include?('tissue_type')
      validate_categorical_values('tissue_type', VALID_TISSUE_TYPES, '/col_attrs')
    end

    # Validate suspension_type values if present
    if col_attrs.include?('suspension_type')
      validate_categorical_values('suspension_type', VALID_SUSPENSION_TYPES, '/col_attrs')
    end

    # Check for Visium-specific fields
    assay = get_metadata_sample('/col_attrs/assay_ontology_term_id')
    if assay && is_visium_assay?(assay)
      is_single = get_global_attr('spatial/is_single') || get_global_attr('spatial_is_single')
      if is_single == true || is_single == 'true'
        %w[array_row array_col in_tissue].each do |field|
          unless col_attrs.include?(field)
            @errors << { field: "/col_attrs/#{field}", message: "REQUIRED for Visium spatial data with is_single=true" }
          end
        end
      end
    end

    # Check for genetic perturbation fields
    has_perturbations = get_global_attr('genetic_perturbations').present?
    if has_perturbations
      unless col_attrs.include?('genetic_perturbation_id')
        @errors << { field: '/col_attrs/genetic_perturbation_id', message: 'REQUIRED when uns["genetic_perturbations"] is present' }
      end
      unless col_attrs.include?('genetic_perturbation_strategy')
        @errors << { field: '/col_attrs/genetic_perturbation_strategy', message: 'REQUIRED when genetic_perturbation_id is present' }
      end
    end
  end

  def validate_required_global_attributes
    global_attrs = @file_info&.dig(:global_attrs) || []

    # Check required global attributes
    REQUIRED_GLOBAL_ATTRS.each do |attr|
      unless global_attrs.include?(attr)
        @errors << { field: "/attrs/#{attr}", message: "REQUIRED global attribute '#{attr}' not found" }
      end
    end

    # Check for ontology label global attributes (required alongside their _ontology_term_id)
    ONTOLOGY_LABEL_GLOBAL_ATTRS.each do |attr|
      unless global_attrs.include?(attr)
        @errors << { field: "/attrs/#{attr}", message: "REQUIRED global attribute '#{attr}' not found. This is the human-readable label for '#{attr}_ontology_term_id'." }
      end
    end

    # Validate organism_ontology_term_id format
    organism = get_global_attr('organism_ontology_term_id')
    if organism
      validate_ontology_term_format(organism, '/attrs/organism_ontology_term_id', VALID_ONTOLOGY_PREFIXES[:organism])
    end
  end

  def validate_ontology_terms
    # All cell metadata ontology fields are in /col_attrs/ in ASAP (cells are columns)
    
    # Validate assay_ontology_term_id format
    validate_ontology_field('/col_attrs/assay_ontology_term_id', VALID_ONTOLOGY_PREFIXES[:assay])
    
    # Validate cell_type_ontology_term_id format (allows "unknown")
    validate_ontology_field('/col_attrs/cell_type_ontology_term_id', VALID_ONTOLOGY_PREFIXES[:cell_type], allow_special: %w[unknown na])
    
    # Validate disease_ontology_term_id format (allows PATO for healthy)
    validate_ontology_field('/col_attrs/disease_ontology_term_id', VALID_ONTOLOGY_PREFIXES[:disease])
    
    # Validate sex_ontology_term_id format (allows "unknown", "na")
    validate_ontology_field('/col_attrs/sex_ontology_term_id', VALID_ONTOLOGY_PREFIXES[:sex], allow_special: %w[unknown na])
    
    # Validate development_stage_ontology_term_id (allows "unknown", "na")
    validate_ontology_field('/col_attrs/development_stage_ontology_term_id', VALID_ONTOLOGY_PREFIXES[:development_stage], allow_special: %w[unknown na])
    
    # Validate tissue_ontology_term_id
    validate_ontology_field('/col_attrs/tissue_ontology_term_id', VALID_ONTOLOGY_PREFIXES[:tissue])
    
    # Validate self_reported_ethnicity_ontology_term_id (allows "unknown", "na")
    validate_ontology_field('/col_attrs/self_reported_ethnicity_ontology_term_id', VALID_ONTOLOGY_PREFIXES[:ethnicity], allow_special: %w[unknown na])
  end

  def validate_ontology_field(path, valid_prefixes, allow_special: [])
    sample = get_metadata_sample(path)
    return unless sample

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
  end

  def validate_ontology_term_format(term, field, valid_prefixes)
    # OBO format: PREFIX:ID (e.g., "CL:0000540")
    # Cellosaurus uses underscore: CVCL_XXXX
    
    if term.start_with?('CVCL_')
      # Cellosaurus format is valid
      return
    end
    
    unless term.match?(/^[A-Za-z]+:\d+$/)
      @errors << { field: field, message: "Invalid ontology term format: '#{term}'. Expected OBO format (PREFIX:ID) like 'CL:0000540'" }
      return
    end

    prefix = term.split(':').first
    unless valid_prefixes.include?(prefix)
      @warnings << { field: field, message: "Ontology prefix '#{prefix}' in '#{term}' may not be valid for this field. Expected: #{valid_prefixes.join(', ')}" }
    end
  end

  def validate_organism_specific_requirements
    organism = get_global_attr('organism_ontology_term_id')
    return unless organism

    # Cell metadata (including development_stage) is in /col_attrs/ in ASAP
    case organism
    when 'NCBITaxon:9606' # Human
      @info << { field: 'organism', message: 'Homo sapiens detected. Checking human-specific requirements.' }
      # Human-specific: HsapDv for development stages, HANCESTRO for ethnicity
      validate_ontology_field('/col_attrs/development_stage_ontology_term_id', ['HsapDv', 'UBERON'], allow_special: %w[unknown na])
    when 'NCBITaxon:10090' # Mouse
      @info << { field: 'organism', message: 'Mus musculus detected. Checking mouse-specific requirements.' }
      validate_ontology_field('/col_attrs/development_stage_ontology_term_id', ['MmusDv', 'UBERON'], allow_special: %w[unknown na])
    when 'NCBITaxon:6239' # C. elegans
      @info << { field: 'organism', message: 'C. elegans detected. Checking C. elegans-specific requirements.' }
      validate_ontology_field('/col_attrs/development_stage_ontology_term_id', ['WBls'], allow_special: %w[unknown na])
    when 'NCBITaxon:7955' # Zebrafish
      @info << { field: 'organism', message: 'Danio rerio detected. Checking zebrafish-specific requirements.' }
      validate_ontology_field('/col_attrs/development_stage_ontology_term_id', ['ZFS', 'UBERON'], allow_special: %w[unknown na])
    when 'NCBITaxon:7227' # Drosophila
      @info << { field: 'organism', message: 'Drosophila melanogaster detected. Checking fly-specific requirements.' }
      validate_ontology_field('/col_attrs/development_stage_ontology_term_id', ['FBdv', 'UBERON'], allow_special: %w[unknown na])
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
    end
  end

  # Helper methods

  def is_visium_assay?(assay_term)
    # EFO:0010961 is Visium Spatial Gene Expression and descendants
    return false unless assay_term
    
    visium_terms = %w[
      EFO:0010961 EFO:0022857 EFO:0022859 EFO:0022860
    ]
    terms = assay_term.to_s.split(' || ').map(&:strip)
    terms.any? { |t| visium_terms.include?(t) }
  end

  def get_global_attr(key)
    @metadata_cache["global:#{key}"] ||= begin
      cmd = asap_command('-T', 'ExtractGlobalAttr', '-attr', key, '-loom', @loom_path)
      stdout, stderr, status = Open3.capture3(*cmd)
      
      if status.success?
        value = stdout.strip
        value.empty? ? nil : value
      else
        nil
      end
    rescue StandardError
      nil
    end
  end

  def get_metadata_sample(path, limit: 10)
    @metadata_cache[path] ||= begin
      cmd = asap_command('-T', 'ExtractMetadata', '-meta', path, '-loom', @loom_path)
      stdout, stderr, status = Open3.capture3(*cmd)
      
      if status.success?
        result = JSON.parse(stdout)
        values = result['values']
        values.is_a?(Array) ? values.first(limit) : values
      else
        nil
      end
    rescue StandardError
      nil
    end
  end

  def asap_command(*args)
    ['docker', 'exec', ASAP_RUN_CONTAINER, 'java', '-jar', '/srv/ASAP.jar'] + args
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
