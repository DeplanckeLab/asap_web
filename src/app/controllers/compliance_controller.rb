# frozen_string_literal: true

require 'open3'
require 'shellwords'

# Controller for scFAIR cell metadata compliance checking
# Provides endpoints to validate cell metadata in loom files
# and view validation results
class ComplianceController < ApplicationController
  before_action :set_project, only: %i[validate_project show_project_result fix_project apply_project_fix project_metadata_fields]
  skip_before_action :authenticate_user!, only: %i[index schema_docs], raise: false

  # GET /compliance
  # Main compliance page showing overview and documentation links
  def index
    @schema_versions = available_schema_versions
    @recent_validations = recent_project_validations if current_user
  end

  # GET /compliance/schema/:version
  # Show schema documentation for a specific version
  def schema_docs
    @version = params[:version] || '7.1.0'
    @doc_path = Rails.root.join('public', "cxg_#{@version.gsub('.', '_')}_loom_paths.html")
    
    unless File.exist?(@doc_path)
      redirect_to compliance_index_path, alert: "Schema documentation for version #{@version} not found"
      return
    end

    # Render the HTML file directly or embed it
    respond_to do |format|
      format.html { render :schema_docs }
    end
  end

  # POST /compliance/validate
  # Start validation for a file (uploaded or existing)
  def validate
    if params[:loom_file].present?
      # Handle uploaded file
      validate_uploaded_file
    elsif params[:project_id].present?
      # Validate existing project
      validate_existing_project
    elsif params[:file_path].present?
      # Validate specific file path
      validate_file_path
    else
      render json: { error: 'No file or project specified for validation' }, status: :unprocessable_entity
    end
  end

  # POST /compliance/projects/:id/validate
  # Trigger validation for a project's loom file
  # Runs synchronously if sidekiq is not available
  def validate_project
    unless @project
      render json: { error: 'Project not found' }, status: :not_found
      return
    end

    # Resolve compliance schema config for this project
    schema_config = resolve_compliance_schema(@project)

    # Find the loom file
    loom_path = find_project_loom_path(@project)
    
    unless loom_path && File.exist?(loom_path)
      error_result = {
        valid: false,
        schema_version: schema_config['version'],
        schema_name: schema_config['name'],
        source_url: schema_config['source_url'],
        source_schema_name: schema_config['source_schema_name'],
        description: schema_config['description'],
        url: schema_config['url'],
        compliant_icon: schema_config['compliant_icon'],
        not_compliant_icon: schema_config['not_compliant_icon'],
        validated_at: Time.current.iso8601,
        error: 'No loom file found. Make sure the parsing step has completed.'
      }
      save_validation_result(@project, error_result)
      
      respond_to do |format|
        format.html { redirect_to compliance_project_result_path(@project), alert: 'No loom file found' }
        format.json { render json: { status: 'error', message: 'No loom file found', project_id: @project.id } }
      end
      return
    end

    # Run validation synchronously
    validator = CxgLoomValidatorService.new(loom_path, project: @project, logger: Rails.logger)
    result = validator.validate
    
    # Save result with schema metadata from compliance config
    validation_data = {
      valid: result.valid?,
      schema_version: result.schema_version,
      schema_name: schema_config['name'],
      source_url: schema_config['source_url'],
      source_schema_name: schema_config['source_schema_name'],
      description: schema_config['description'],
      url: schema_config['url'],
      compliant_icon: schema_config['compliant_icon'],
      not_compliant_icon: schema_config['not_compliant_icon'],
      validated_at: result.validated_at,
      loom_path: loom_path,
      errors: result.errors,
      warnings: result.warnings,
      info: result.info,
      errors_count: result.errors.count,
      warnings_count: result.warnings.count,
      info_count: result.info.count
    }
    save_validation_result(@project, validation_data)

    respond_to do |format|
      format.html do
        if result.valid?
          redirect_to compliance_project_result_path(@project), notice: 'Validation passed!'
        else
          redirect_to compliance_project_result_path(@project), alert: "Validation found #{result.errors.count} error(s)"
        end
      end
      format.json do
        render json: { 
          status: 'completed',
          valid: result.valid?,
          errors_count: result.errors.count,
          warnings_count: result.warnings.count,
          info_count: result.info.count,
          project_id: @project.id 
        }
      end
    end
  end

  # GET /compliance/projects/:id/result
  # Show validation result for a specific project
  def show_project_result
    unless @project
      redirect_to compliance_index_path, alert: 'Project not found'
      return
    end

    @validation_result = load_validation_result(@project)
    @loom_files = find_project_loom_files(@project)
  end

  # GET /compliance/projects/:id/status
  # Get validation status (for AJAX polling)
  def project_status
    project = Project.find_by(id: params[:id])
    
    unless project
      render json: { error: 'Project not found' }, status: :not_found
      return
    end

    result = load_validation_result(project)
    
    render json: {
      project_id: project.id,
      has_result: result.present?,
      valid: result&.dig(:valid),
      validated_at: result&.dig(:validated_at),
      errors_count: result&.dig(:errors_count) || result&.dig(:errors)&.count || 0,
      warnings_count: result&.dig(:warnings_count) || result&.dig(:warnings)&.count || 0,
      schema_version: result&.dig(:schema_version)
    }
  end

  # POST /compliance/validate_file
  # Validate a file synchronously (for quick checks or API usage)
  def validate_file
    file_path = params[:file_path]
    
    unless file_path && File.exist?(file_path)
      render json: { error: 'File not found', path: file_path }, status: :not_found
      return
    end

    validator = CxgLoomValidatorService.new(file_path, logger: Rails.logger)
    result = validator.validate

    render json: {
      valid: result.valid?,
      schema_version: result.schema_version,
      validated_at: result.validated_at,
      errors: result.errors,
      warnings: result.warnings,
      info: result.info,
      summary: {
        errors_count: result.errors.count,
        warnings_count: result.warnings.count,
        info_count: result.info.count
      }
    }
  end

  # GET /compliance/projects/:id/fix
  # Show the fix compliance form with metadata mapping options
  def fix_project
    unless @project
      redirect_to compliance_index_path, alert: 'Project not found'
      return
    end

    @validation_result = load_validation_result(@project)
    unless @validation_result
      redirect_to compliance_project_result_path(@project), alert: 'No validation result found. Please run validation first.'
      return
    end

    @loom_path = find_project_loom_path(@project)
    unless @loom_path && File.exist?(@loom_path)
      redirect_to compliance_project_result_path(@project), alert: 'No loom file found.'
      return
    end

    # Get the list of existing metadata fields in the loom file
    @available_col_attrs = extract_available_metadata(@project, @loom_path, :col_attrs)
    @available_global_attrs = extract_available_metadata(@project, @loom_path, :global_attrs)

    # Parse validation errors to identify fixable field groups (paired term+label)
    @fixable_groups = build_fixable_field_groups(@validation_result)
    @schema_config = resolve_compliance_schema(@project)
    @organism_info = resolve_organism_info(@project)
    @project_title = @project.respond_to?(:name) ? @project.name : nil

    # Filter ontology prefixes per field group to only those applicable for
    # the project's organism (e.g. FBbt for Drosophila, not WBbt or ZFA).
    @fixable_groups.each do |fg|
      g = fg[:group]
      next unless g[:term_ontology_prefixes].present?
      g[:term_ontology_prefixes] = filter_prefixes_for_organism(g[:term_ontology_prefixes], @project)
    end

    # Load existing OtProject records for prefilling the form
    @prefill_data = build_prefill_data(@project)

    # For compliant fields that were fixed by the compliance tool, pre-load their
    # current unique values from the LOOM so we can display them in the form.
    compliant_paths = []
    compliant_groups = []
    @fixable_groups.each do |fg|
      g = fg[:group]
      next if fg[:term_has_error]
      next if g[:label_path].present? && fg[:label_has_error]
      next if g[:auto_from_project] # organism/title are auto-filled, no need
      compliant_paths << g[:term_path]
      compliant_paths << g[:label_path] if g[:label_path].present?
      compliant_groups << g
    end
    raw_values = compliant_paths.any? ? batch_read_field_values(@loom_path, compliant_paths) : {}

    # Resolve each value against the ontology to detect unresolved terms.
    # Result: { "/col_attrs/tissue" => { "fat body" => true, "body" => false }, ... }
    @compliant_field_values = raw_values
    @compliant_field_resolved = resolve_compliant_field_values(compliant_groups, raw_values)
  end

  # POST /compliance/projects/:id/apply_fix
  # Apply metadata fixes to the loom file
  def apply_project_fix
    unless @project
      respond_to do |format|
        format.json { render json: { status: 'error', message: 'Project not found' }, status: :not_found }
        format.html { redirect_to root_path, alert: 'Project not found.' }
      end
      return
    end

    loom_path = find_project_loom_path(@project)
    unless loom_path && File.exist?(loom_path)
      respond_to do |format|
        format.json { render json: { status: 'error', message: 'No loom file found.' }, status: :not_found }
        format.html { redirect_to compliance_project_fix_path(@project), alert: 'No loom file found.' }
      end
      return
    end

    fixes = params[:fixes] || {}
    applied = []
    errors = []

    # Track which paths have been versioned in this batch to avoid double-archives
    # and to adjust source paths that point to a just-archived field.
    versioned_paths = {} # { original_path => archive_path }

    fixes.each do |field_path, fix_data|
      next if fix_data[:action].blank? || fix_data[:action] == 'skip'

      action = fix_data[:action]
      field_path = field_path.to_s

      begin
        if action == 'map_from'
          source_path = fix_data[:source].to_s.strip
          next if source_path.blank?

          new_annot = version_and_replace_metadata(@project, loom_path, field_path, versioned_paths, rename_annot: true) do |lp, fp|
            actual_source = adjust_source_if_versioned(source_path, versioned_paths)
            success = copy_metadata_in_loom(lp, actual_source, fp)
            unless success
              raise "Failed to copy from #{actual_source}"
            end
          end
          applied << { field: field_path, action: 'mapped', source: source_path }

        elsif action == 'resolve_paired'
          source_path = fix_data[:source].to_s.strip
          resolve_map_json = fix_data[:resolve_map].to_s.strip
          next if source_path.blank? || resolve_map_json.blank?

          new_annot = version_and_replace_metadata(@project, loom_path, field_path, versioned_paths, rename_annot: true) do |lp, fp|
            actual_source = adjust_source_if_versioned(source_path, versioned_paths)
            success = resolve_paired_in_loom(lp, actual_source, fp, resolve_map_json)
            unless success
              raise "Failed to resolve paired values from #{actual_source}"
            end
          end
          applied << { field: field_path, action: 'resolve_paired', source: source_path }

        elsif action == 'set_value'
          value = fix_data[:value].to_s.strip
          next if value.blank?

          new_annot = version_and_replace_metadata(@project, loom_path, field_path, versioned_paths, rename_annot: true) do |lp, fp|
            if fp.start_with?('/attrs/')
              success = write_global_attr_to_loom(lp, fp, value)
            else
              success = write_constant_to_loom(lp, fp, value)
            end
            unless success
              raise "Failed to write value '#{value}'"
            end
          end
          applied << { field: field_path, action: 'set_value', value: value }
        end
      rescue StandardError => e
        Rails.logger.error("[Compliance Fix] Error fixing #{field_path}: #{e.message}")
        errors << { field: field_path, message: e.message }
      end
    end

    # Record compliance mappings for tracking how metadata vectors are generated
    if applied.any?
      record_compliance_mappings(@project, applied, fixes)
    end

    result_url = compliance_project_result_path(@project)

    unless applied.any?
      respond_to do |format|
        format.json { render json: { status: 'error', message: 'No changes were applied.', redirect_url: result_url } }
        format.html { redirect_to compliance_project_fix_path(@project), alert: 'No changes were applied.' }
      end
      return
    end

    # Apply fixes to all LOOM file variants (cell-filtered, gene-filtered).
    # Pass versioned_paths from the main pass so variants use the same archive paths.
    apply_fixes_to_loom_variants(@project, loom_path, applied, fixes, versioned_paths)

    # Broadcast progress via websocket
    ActionCable.server.broadcast("compliance_#{@project.id}", {
      project_id: @project.id,
      status: 'applying',
      message: "Applied #{applied.count} fix(es) to #{count_loom_variants(@project, loom_path)} LOOM file(s). Running validation...",
      timestamp: Time.current.iso8601
    })

    # Trigger async validation and respond immediately
    CxgValidationJob.perform_later(@project.id)

    respond_to do |format|
      format.json do
        error_summary = errors.any? ? " (#{errors.count} error(s): #{errors.map { |e| e[:message] }.first(3).join(', ')})" : ''
        render json: {
          status: 'ok',
          message: "Applied #{applied.count} fix(es)#{error_summary}. Running validation...",
          applied_count: applied.count,
          errors_count: errors.count,
          validating: true,
          redirect_url: result_url
        }
      end
      format.html do
        flash[:notice] = "Applied #{applied.count} fix(es). Validation is running..."
        redirect_to result_url
      end
    end
  end

  # GET /compliance/ontology_autocomplete (JSON)
  # Search cell_ontology_terms for autocomplete in the fix form.
  # Params:
  #   term       - search query (matches identifier or name)
  #   prefixes   - comma-separated ontology prefixes (e.g., "CL,WBbt,ZFA,FBbt")
  #   project_id - optional project ID to restrict ontologies by organism
  def ontology_autocomplete
    query = params[:term].to_s.strip
    prefixes = params[:prefixes].to_s.split(',').map(&:strip).reject(&:blank?)

    if query.blank? || prefixes.blank?
      render json: { results: [], total_count: 0 }
      return
    end

    # Map ontology prefixes to cell_ontology_ids, filtered by organism
    ontology_ids = organism_scoped_ontology_ids(prefixes, params[:project_id])
    if ontology_ids.empty?
      render json: { results: [], total_count: 0 }
      return
    end

    scope = CellOntologyTerm.where(original: true, cell_ontology_id: ontology_ids)

    # Search by identifier or name
    search_pattern = "%#{query}%"
    matched_scope = scope.where('identifier ILIKE :q OR name ILIKE :q', q: search_pattern)

    # Count total matches before limiting
    total_count = matched_scope.count

    # Sort by relevance:
    #   0 = exact match on identifier (case-insensitive)
    #   1 = exact match on name (case-insensitive)
    #   2 = identifier starts with query
    #   3 = name starts with query
    #   4 = identifier contains query
    #   5 = name contains query
    #   Then alphabetically by name within each tier
    exact_q = ActiveRecord::Base.connection.quote(query)
    starts_q = ActiveRecord::Base.connection.quote("#{query}%")

    relevance_sql = <<~SQL.squish
      CASE
        WHEN identifier ILIKE #{exact_q} THEN 0
        WHEN name ILIKE #{exact_q} THEN 1
        WHEN identifier ILIKE #{starts_q} THEN 2
        WHEN name ILIKE #{starts_q} THEN 3
        WHEN identifier ILIKE #{ActiveRecord::Base.connection.quote("%#{query}%")} THEN 4
        ELSE 5
      END, name ASC
    SQL

    results = matched_scope
      .order(Arel.sql(relevance_sql))
      .limit(25)
      .pluck(:id, :identifier, :name)

    render json: {
      results: results.map { |id, identifier, name| { id: id, identifier: identifier, name: name, label: "#{identifier} - #{name}" } },
      total_count: total_count
    }
  end

  # POST /compliance/resolve_ontology_terms (JSON)
  # Given a list of values (identifiers or names), resolve them to their paired counterpart.
  # Params:
  #   values   - JSON array of strings to resolve
  #   prefixes - comma-separated ontology prefixes
  #   mode     - "by_identifier" (values are identifiers, return names)
  #              or "by_name" (values are names, return identifiers)
  def resolve_ontology_terms
    values = begin
      JSON.parse(params[:values] || '[]')
    rescue JSON::ParserError
      []
    end
    prefixes = params[:prefixes].to_s.split(',').map(&:strip).reject(&:blank?)
    mode = params[:mode].to_s

    if values.blank? || prefixes.blank? || !%w[by_identifier by_name].include?(mode)
      render json: { resolved: {}, multi_term_map: {} }
      return
    end

    ontology_ids = organism_scoped_ontology_ids(prefixes, params[:project_id])
    if ontology_ids.empty?
      render json: { resolved: {}, multi_term_map: {} }
      return
    end

    resolved = {}
    # Track which values are multi-term (array-formatted) so the frontend can
    # render them distinctly and the resolve_map uses || as separator.
    multi_term_map = {}
    # Track canonical names when source values don't match exactly
    canonical_names = {}
    scope = CellOntologyTerm.where(original: true, cell_ontology_id: ontology_ids)

    # Separate plain values from array-formatted values like "['FBbt:00003733', 'FBbt:00003737']"
    plain_values = []
    array_values = [] # Each entry: { original: "['a','b']", items: ["a","b"] }

    values.each do |val|
      parsed = parse_array_value(val)
      if parsed
        array_values << { original: val, items: parsed }
      else
        plain_values << val
      end
    end

    if mode == 'by_identifier'
      # Given identifiers, find names
      # First resolve all plain identifiers in one query
      all_identifiers = plain_values + array_values.flat_map { |av| av[:items] }
      terms_by_ident = {}
      scope.where(identifier: all_identifiers.uniq).pluck(:identifier, :name).each do |ident, name|
        terms_by_ident[ident] = name
      end

      plain_values.each do |ident|
        resolved[ident] = terms_by_ident[ident] if terms_by_ident[ident]
      end

      array_values.each do |av|
        resolved_items = av[:items].map { |ident| terms_by_ident[ident] }
        if resolved_items.all?
          # All items resolved: map original string to ||-joined identifiers and names
          resolved[av[:original]] = resolved_items.join(' || ')
          multi_term_map[av[:original]] = av[:items].join(' || ')
        end
        # If not all resolved, leave it unresolved so the user can fix it manually
      end
    else
      # Given names, find identifiers (case-insensitive)
      # Also return canonical_names so the frontend can detect when the source
      # value doesn't exactly match the ontology name (e.g. "fat_body" vs "fat body").
      canonical_names = {}

      # Batch-resolve all names in as few queries as possible
      all_names = plain_values.map(&:strip) + array_values.flat_map { |av| av[:items].map(&:strip) }
      name_to_term = batch_find_ontology_terms_by_name(scope, all_names.uniq)

      # Resolve plain names
      plain_values.each do |name|
        match = name_to_term[name.strip]
        if match
          resolved[name] = match[:identifier]
          canonical_names[name] = match[:name] if match[:name] != name
        end
      end

      array_values.each do |av|
        resolved_items = av[:items].map { |name| name_to_term[name.strip] }
        if resolved_items.all?
          resolved[av[:original]] = resolved_items.map { |m| m[:identifier] }.join(' || ')
          multi_term_map[av[:original]] = av[:items].join(' || ')
          canonical = resolved_items.map { |m| m[:name] }.join(' || ')
          original_joined = av[:items].join(' || ')
          canonical_names[av[:original]] = canonical if canonical != original_joined
        end
      end
    end

    render json: { resolved: resolved, multi_term_map: multi_term_map, canonical_names: canonical_names }
  end

  # GET /compliance/projects/:id/metadata_fields (JSON)
  # Returns available metadata fields and their sample values for the form
  def project_metadata_fields
    unless @project
      render json: { error: 'Project not found' }, status: :not_found
      return
    end

    loom_path = find_project_loom_path(@project)
    unless loom_path
      render json: { error: 'No loom file found' }, status: :not_found
      return
    end

    field_path = params[:field_path].to_s
    return render(json: { error: 'Missing field_path' }, status: :bad_request) if field_path.blank?

    # Extract sample values for the requested metadata field
    values = H5DataService.get_metadata_values(loom_path, field_path)
    render json: { field: field_path, values: values }
  end

  private

  # Batch-resolve many names at once using two queries (exact match + underscore-to-space).
  # Returns a hash { name => { identifier:, name: } } for found terms.
  def batch_find_ontology_terms_by_name(scope, names)
    return {} if names.blank?

    result = {}
    remaining = []

    # Step 1: batch exact match (case-insensitive) using LOWER()
    lower_map = {}
    names.each { |n| lower_map[n.downcase] = n }

    scope.where('LOWER(name) IN (?)', lower_map.keys)
         .pluck(:name, :identifier).each do |db_name, identifier|
      original = lower_map[db_name.downcase]
      next unless original && !result.key?(original)
      result[original] = { identifier: identifier, name: db_name }
    end

    # Find which names are still unresolved
    remaining = names.select { |n| !result.key?(n) }

    # Step 2: for names with underscores, try replacing _ with space
    underscore_names = remaining.select { |n| n.include?('_') }
    if underscore_names.any?
      spaced_map = {}
      underscore_names.each { |n| spaced_map[n.tr('_', ' ').downcase] = n }

      scope.where('LOWER(name) IN (?)', spaced_map.keys)
           .pluck(:name, :identifier).each do |db_name, identifier|
        original = spaced_map[db_name.downcase]
        next unless original && !result.key?(original)
        result[original] = { identifier: identifier, name: db_name }
      end
    end

    result
  end

  # Find an ontology term by name, case-insensitively.
  # First tries an exact case-insensitive match (with ILIKE wildcards escaped),
  # then tries replacing underscores with spaces (common in LOOM metadata).
  def find_ontology_term_by_name(scope, name)
    escaped = name.gsub('%', '\\%').gsub('_', '\\_')
    match = scope.where('name ILIKE ?', escaped).order(:id).first
    return match if match

    if name.include?('_')
      spaced = name.tr('_', ' ')
      escaped_spaced = spaced.gsub('%', '\\%').gsub('_', '\\_')
      scope.where('name ILIKE ?', escaped_spaced).order(:id).first
    end
  end

  # Parse a string like "['FBbt:00003733', 'FBbt:00003737']" into an array of individual values.
  # Returns nil if the string is not in array format.
  def parse_array_value(val)
    stripped = val.to_s.strip
    return nil unless stripped.start_with?('[') && stripped.end_with?(']')

    # Remove brackets and split on commas, then strip quotes and whitespace
    inner = stripped[1..-2]
    items = inner.split(',').map { |item| item.strip.gsub(/\A['"]|['"]\z/, '') }.reject(&:blank?)
    items.presence
  end

  # Apply the same fixes to all LOOM file variants (cell-filtered, gene-filtered).
  # The main loom_path has already been fixed; this replicates fixes to variants.
  # DB updates (Annot records, Run JSON) were already done for the main file,
  # so rename_annot: false is used here -- only the LOOM files are modified.
  def apply_fixes_to_loom_variants(project, main_loom_path, applied, fixes, main_versioned_paths)
    all_loom_files = find_project_loom_files(project)
    variant_files = all_loom_files.reject { |f| File.realpath(f) == File.realpath(main_loom_path) }

    return if variant_files.empty?

    Rails.logger.info("[Compliance Fix] Applying fixes to #{variant_files.size} LOOM variant(s)")

    variant_files.each do |variant_path|
      Rails.logger.info("[Compliance Fix] Processing variant: #{variant_path}")
      variant_versioned = {}

      applied.each do |entry|
        field_path = entry[:field]
        action = entry[:action]

        begin
          fix_data = fixes[field_path] || {}

          if action == 'mapped'
            source_path = entry[:source] || fix_data[:source].to_s.strip
            next if source_path.blank?
            version_and_replace_metadata(project, variant_path, field_path, variant_versioned, rename_annot: false, expected_archive_paths: main_versioned_paths) do |lp, fp|
              actual_source = adjust_source_if_versioned(source_path, variant_versioned)
              copy_metadata_in_loom(lp, actual_source, fp)
            end

          elsif action == 'resolve_paired'
            source_path = entry[:source] || fix_data[:source].to_s.strip
            resolve_map_json = fix_data[:resolve_map].to_s.strip
            next if source_path.blank? || resolve_map_json.blank?
            version_and_replace_metadata(project, variant_path, field_path, variant_versioned, rename_annot: false, expected_archive_paths: main_versioned_paths) do |lp, fp|
              actual_source = adjust_source_if_versioned(source_path, variant_versioned)
              resolve_paired_in_loom(lp, actual_source, fp, resolve_map_json)
            end

          elsif action == 'set_value'
            value = entry[:value] || fix_data[:value].to_s.strip
            next if value.blank?
            version_and_replace_metadata(project, variant_path, field_path, variant_versioned, rename_annot: false, expected_archive_paths: main_versioned_paths) do |lp, fp|
              if fp.start_with?('/attrs/')
                write_global_attr_to_loom(lp, fp, value)
              else
                write_constant_to_loom(lp, fp, value)
              end
            end
          end
        rescue StandardError => e
          Rails.logger.error("[Compliance Fix] Error applying #{action} to variant #{variant_path} field #{field_path}: #{e.message}")
        end
      end
    end
  end

  # Count total LOOM files (main + variants) for the progress message
  def count_loom_variants(project, main_loom_path)
    all_loom_files = find_project_loom_files(project)
    all_loom_files.size
  end

  def set_project
    @project = Project.find_by(id: params[:id] || params[:project_id])
  end

  def validate_uploaded_file
    uploaded = params[:loom_file]
    
    unless uploaded.original_filename.end_with?('.loom')
      render json: { error: 'File must be a .loom file' }, status: :unprocessable_entity
      return
    end

    # Save temporarily
    temp_path = Rails.root.join('tmp', 'uploads', "validation_#{SecureRandom.hex(8)}.loom")
    FileUtils.mkdir_p(File.dirname(temp_path))
    
    begin
      File.open(temp_path, 'wb') { |f| f.write(uploaded.read) }
      
      validator = CxgLoomValidatorService.new(temp_path.to_s, logger: Rails.logger)
      result = validator.validate

      render json: {
        valid: result.valid?,
        filename: uploaded.original_filename,
        schema_version: result.schema_version,
        validated_at: result.validated_at,
        errors: result.errors,
        warnings: result.warnings,
        info: result.info
      }
    ensure
      FileUtils.rm_f(temp_path) if File.exist?(temp_path)
    end
  end

  def validate_existing_project
    project = Project.find_by(id: params[:project_id])
    
    unless project
      render json: { error: 'Project not found' }, status: :not_found
      return
    end

    # Check permissions if user is logged in
    if current_user && !can_access_project?(project)
      render json: { error: 'Not authorized to validate this project' }, status: :forbidden
      return
    end

    CxgValidationJob.perform_later(project.id)
    render json: { status: 'queued', project_id: project.id }
  end

  def validate_file_path
    file_path = params[:file_path]
    
    # Security check - only allow certain directories
    allowed_dirs = [
      ENV.fetch('USER_DATA_DIR', '/data/asap2/projects'),
      ENV.fetch('UPLOAD_DATA_DIR', '/data/asap2/fus')
    ]

    unless allowed_dirs.any? { |dir| file_path.start_with?(dir) }
      render json: { error: 'File path not allowed' }, status: :forbidden
      return
    end

    unless File.exist?(file_path)
      render json: { error: 'File not found' }, status: :not_found
      return
    end

    validator = CxgLoomValidatorService.new(file_path, logger: Rails.logger)
    result = validator.validate

    render json: {
      valid: result.valid?,
      file_path: file_path,
      schema_version: result.schema_version,
      errors: result.errors,
      warnings: result.warnings,
      info: result.info
    }
  end

  def load_validation_result(project)
    # Try loading from project.cxg_validation_result method
    # This method returns a Hash (already parsed), so we just need to symbolize keys
    if project.respond_to?(:cxg_validation_result)
      result = project.cxg_validation_result
      if result.present?
        # The model method returns a Hash with string keys, convert to symbol keys
        return result.deep_symbolize_keys
      end
    end

    if project.respond_to?(:metadata) && project.metadata&.dig('cxg_validation')
      return project.metadata['cxg_validation'].deep_symbolize_keys
    end

    # Try loading from project directory first (primary location)
    if project.respond_to?(:key) && project.respond_to?(:user_id) && project.key.present? && project.user_id.present?
      project_validation_path = File.join(
        ENV.fetch('USER_DATA_DIR', '/data/asap2/projects'),
        project.user_id.to_s,
        project.key,
        'cxg_validation_result.json'
      )
      
      if File.exist?(project_validation_path)
        begin
          return JSON.parse(File.read(project_validation_path), symbolize_names: true)
        rescue JSON::ParserError
          nil
        end
      end
    end

    # Fall back to upload directory
    validation_path = File.join(
      ENV.fetch('UPLOAD_DATA_DIR', '/data/asap2/fus'),
      project.id.to_s,
      'cxg_validation_result.json'
    )

    if File.exist?(validation_path)
      begin
        return JSON.parse(File.read(validation_path), symbolize_names: true)
      rescue JSON::ParserError
        nil
      end
    end

    nil
  end

  def find_project_loom_files(project)
    loom_files = []

    # Check project directory
    if project.respond_to?(:key) && project.respond_to?(:user_id)
      project_dir = File.join(
        ENV.fetch('USER_DATA_DIR', '/data/asap2/projects'),
        project.user_id.to_s,
        project.key
      )
      
      if File.directory?(project_dir)
        loom_files += Dir.glob(File.join(project_dir, '**', '*.loom'))
      end
    end

    # Check upload directory
    upload_dir = File.join(
      ENV.fetch('UPLOAD_DATA_DIR', '/data/asap2/fus'),
      project.id.to_s
    )
    
    if File.directory?(upload_dir)
      loom_files += Dir.glob(File.join(upload_dir, '**', '*.loom'))
    end

    loom_files.uniq
  end

  # Find the primary loom file for validation (parsing/output.loom)
  def find_project_loom_path(project)
    return nil unless project.respond_to?(:key) && project.respond_to?(:user_id)
    return nil unless project.key.present? && project.user_id.present?

    user_data_dir = ENV.fetch('USER_DATA_DIR', '/data/asap2/projects')
    
    # Primary location: parsing/output.loom
    parsing_output = File.join(user_data_dir, project.user_id.to_s, project.key, 'parsing', 'output.loom')
    return parsing_output if File.exist?(parsing_output)
    
    # Find any loom file in the project directory
    project_dir = File.join(user_data_dir, project.user_id.to_s, project.key)
    if File.directory?(project_dir)
      loom_files = Dir.glob(File.join(project_dir, '**', '*.loom'))
      return loom_files.first if loom_files.any?
    end
    
    nil
  end

  # Save validation result to project directory
  def save_validation_result(project, validation_data)
    return unless project.respond_to?(:key) && project.respond_to?(:user_id)
    return unless project.key.present? && project.user_id.present?

    validation_path = File.join(
      ENV.fetch('USER_DATA_DIR', '/data/asap2/projects'),
      project.user_id.to_s,
      project.key,
      'cxg_validation_result.json'
    )
    
    begin
      FileUtils.mkdir_p(File.dirname(validation_path))
      File.write(validation_path, JSON.pretty_generate(validation_data))
      Rails.logger.info("[Compliance] Saved validation result to: #{validation_path}")
    rescue StandardError => e
      Rails.logger.error("[Compliance] Could not save validation result: #{e.message}")
    end
  end

  # Resolve the first compliance schema config for a project's type from its version
  # Returns a hash with all schema fields, with sensible defaults
  def resolve_compliance_schema(project)
    schemas = project.version&.compliance_schemas_for(project.project_type_id) || []
    schema = schemas.first || {}
    {
      'name' => schema['name'],
      'version' => schema['version'],
      'source_url' => schema['source_url'],
      'source_schema_name' => schema['source_schema_name'],
      'description' => schema['description'],
      'url' => schema['url'],
      'compliant_icon' => schema['compliant_icon'],
      'not_compliant_icon' => schema['not_compliant_icon']
    }.compact
  end

  def can_access_project?(project)
    return true if admin?
    return false unless current_user
    
    project.user_id == current_user.id || project.shares.exists?(user_id: current_user.id)
  end

  def admin?
    current_user&.respond_to?(:admin?) && current_user.admin?
  end

  def available_schema_versions
    # List available schema documentation versions
    schema_files = Dir.glob(Rails.root.join('public', 'cxg_*_loom_paths.html'))
    schema_files.map do |path|
      filename = File.basename(path, '.html')
      match = filename.match(/cxg_(\d+)_(\d+)_(\d+)_loom_paths/)
      match ? "#{match[1]}.#{match[2]}.#{match[3]}" : nil
    end.compact.sort.reverse
  end

  def recent_project_validations
    # Get recent validation results for current user's projects
    return [] unless current_user

    projects = Project.where(user_id: current_user.id).order(updated_at: :desc).limit(10)
    projects.map do |project|
      result = load_validation_result(project)
      {
        project: project,
        validation: result
      } if result
    end.compact
  end

  # Extract available metadata fields from the loom file
  # type: :col_attrs or :global_attrs
  def extract_available_metadata(project, loom_path, type)
    # Try from Annot records first (fast)
    prefix = type == :col_attrs ? '/col_attrs/' : '/attrs/'
    annot_names = project.annots.pluck(:name).compact
    fields = annot_names.select { |n| n.start_with?(prefix) }.map { |n| n.sub(prefix, '') }.sort

    return fields if fields.any?

    # Fall back to ListMetadata from loom file
    output_file = "/tmp/compliance_meta_#{SecureRandom.hex(8)}.json"
    cmd = H5DataService.asap_command('-T', 'ListMetadata', '-f', loom_path, '-o', output_file)
    _stdout, _stderr, status = Open3.capture3(*cmd)

    return [] unless status.success? && File.exist?(output_file)

    begin
      raw = JSON.parse(File.read(output_file))
      entries = raw['metadata'] || []
      entries.select { |e| e['name'].to_s.start_with?(prefix) }
             .map { |e| e['name'].sub(prefix, '') }
             .sort
    rescue JSON::ParserError
      []
    ensure
      FileUtils.rm_f(output_file)
    end
  end

  # For each compliant field, check whether each value resolves to a known
  # ontology term or matches a valid value list.
  # Returns { field_path => { value => bool } }.
  def resolve_compliant_field_values(groups, raw_values)
    result = {}

    groups.each do |g|
      valid_values = g[:term_valid_values]
      prefixes = g[:term_ontology_prefixes]

      # Fields with a fixed valid-values list (e.g. tissue_type, suspension_type)
      if valid_values.present?
        term_vals = raw_values[g[:term_path]] || []
        if term_vals.any?
          valid_set = valid_values.map(&:downcase).to_set
          result[g[:term_path]] = term_vals.index_with { |v| valid_set.include?(v.downcase) }
        end
        next
      end

      # Ontology-based fields
      next if prefixes.blank?

      ontology_ids = CellOntology.where(tag: prefixes).pluck(:id)
      next if ontology_ids.empty?

      scope = CellOntologyTerm.where(original: true, cell_ontology_id: ontology_ids)

      # Check the term path (identifiers like PATO:0000383)
      term_vals = raw_values[g[:term_path]] || []
      if term_vals.any?
        known_ids = scope.where(identifier: term_vals).pluck(:identifier).to_set
        result[g[:term_path]] = term_vals.index_with { |v| known_ids.include?(v) }
      end

      # Check the label path (names like "fat body") using batch resolution
      if g[:label_path].present?
        label_vals = raw_values[g[:label_path]] || []
        if label_vals.any?
          name_to_term = batch_find_ontology_terms_by_name(scope, label_vals)
          result[g[:label_path]] = label_vals.index_with { |v| name_to_term.key?(v) }
        end
      end
    end

    result
  end

  # Read unique values for multiple metadata fields from the LOOM in a single call.
  # Returns a hash { "/col_attrs/sex" => ["female", "male", "mixed sex"], ... }
  def batch_read_field_values(loom_path, field_paths)
    return {} if field_paths.blank? || loom_path.blank?

    container = ENV.fetch('ASAP_RUN_CONTAINER', 'asap_run')
    fields_json = field_paths.to_json

    script = <<~PY
      import h5py, sys, json
      f = h5py.File(sys.argv[1], 'r')
      fields = json.loads(sys.argv[2])
      result = {}
      for fp in fields:
          parts = fp.lstrip('/').split('/')
          try:
              ds = f
              for p in parts:
                  ds = ds[p]
              vals = ds[:]
              unique = sorted(set(v.decode() if hasattr(v, 'decode') else str(v) for v in vals))
              result[fp] = unique
          except Exception:
              result[fp] = []
      f.close()
      print(json.dumps(result))
    PY

    stdout, _stderr, status = Open3.capture3(
      'docker', 'exec', container, 'python3', '-c', script, loom_path, fields_json
    )
    return {} unless status.success?

    JSON.parse(stdout) rescue {}
  end

  # Load compliance field group definitions from the database.
  # Returns an array of hashes with the same structure previously held by FIELD_GROUPS.
  # Pre-loads CellOntology tags in a single query to avoid N+1.
  def load_field_groups
    otts = OntologyTermType.compliance_field_groups.to_a
    all_co_ids = otts.flat_map(&:cell_ontology_ids_list).uniq
    co_id_to_tag = all_co_ids.any? ? CellOntology.where(id: all_co_ids).pluck(:id, :tag).to_h : {}
    otts.map { |ott| ott.to_field_group(co_id_to_tag) }
  end

  # Build fixable field groups from validation errors.
  # Returns ALL field groups (not just those with errors) so that previously-fixed
  # fields can still be overridden. Groups without errors are included with
  # term_has_error / label_has_error set to false.
  def build_fixable_field_groups(validation_result)
    error_fields = (validation_result[:errors] || []).map { |e| e[:field].to_s }
    error_map = {}
    (validation_result[:errors] || []).each { |e| error_map[e[:field].to_s] = e[:message].to_s }

    groups = []
    load_field_groups.each do |group|
      term_has_error = error_fields.include?(group[:term_path])
      label_has_error = group[:label_path].present? && error_fields.include?(group[:label_path])

      groups << {
        group: group,
        term_has_error: term_has_error,
        label_has_error: label_has_error,
        term_error: error_map[group[:term_path]],
        label_error: error_map[group[:label_path]]
      }
    end
    groups
  end

  # Resolve organism info from the project for auto-fill
  def resolve_organism_info(project)
    organism = project.organism
    return nil unless organism

    {
      name: organism.name,
      short_name: organism.short_name,
      tax_id: organism.tax_id,
      ontology_term_id: "NCBITaxon:#{organism.tax_id}"
    }
  end

  # Filter ontology prefixes to only those applicable for the project's organism.
  # An ontology is applicable if its tax_ids is blank (universal) or contains
  # the organism's tax_id.
  def filter_prefixes_for_organism(prefixes, project)
    return prefixes if prefixes.blank?
    organism = project.organism
    return prefixes unless organism&.tax_id.present?

    tax_id = organism.tax_id.to_s
    applicable_tags = CellOntology.where(tag: prefixes).select { |co|
      co.tax_ids.blank? || co.tax_id_list.map(&:to_s).include?(tax_id)
    }.map(&:tag)
    applicable_tags
  end

  # Filter CellOntology IDs from the given prefix tags by organism applicability.
  # Returns ontology IDs that are either universal or match the given tax_id.
  def organism_scoped_ontology_ids(prefixes, project_id)
    ontology_ids = CellOntology.where(tag: prefixes).pluck(:id, :tag, :tax_ids)
    return ontology_ids.map(&:first) unless project_id.present?

    project = Project.find_by(id: project_id)
    return ontology_ids.map(&:first) unless project&.organism&.tax_id.present?

    tax_id_str = project.organism.tax_id.to_s
    ontology_ids.select { |_id, _tag, tax_ids|
      tax_ids.blank? || tax_ids.to_s.split(',').map(&:strip).include?(tax_id_str)
    }.map(&:first)
  end

  # Build prefill data from existing OtProject records and recent ComplianceMappings.
  # Returns a hash keyed by field_group_id with source annot info and term assignments.
  def build_prefill_data(project)
    prefill = {}

    # Load OntologyTermType records that have a field_group_id mapping
    otts = OntologyTermType.where.not(field_group_id: [nil, '']).to_a

    # Load OtProject records with eager-loaded associations
    ot_projects = OtProject.where(project_id: project.id)
      .includes(:cell_ontology_term, :annot)
      .to_a

    # Group OtProject records by ontology_term_type_id
    by_ott = ot_projects.group_by(&:ontology_term_type_id)

    otts.each do |ott|
      field_group_id = ott.field_group_id
      next unless field_group_id.present?

      records = by_ott[ott.id] || []
      next if records.empty?

      # Determine the source annot (most common annot_id across records)
      annot_ids = records.map(&:annot_id).compact
      source_annot_id = annot_ids.tally.max_by { |_, count| count }&.first
      source_annot = source_annot_id ? Annot.find_by(id: source_annot_id) : nil

      # Collect term assignments: identifier -> name from cell_ontology_term
      terms = records.filter_map do |otp|
        if otp.cell_ontology_term
          {
            identifier: otp.cell_ontology_term.identifier,
            name: otp.cell_ontology_term.name,
            cell_ontology_term_id: otp.cell_ontology_term_id
          }
        elsif otp.free_text.present?
          { identifier: nil, name: otp.free_text, cell_ontology_term_id: nil }
        end
      end.uniq { |t| t[:identifier] || t[:name] }

      prefill[field_group_id] = {
        source_annot_id: source_annot_id,
        source_annot_name: source_annot&.name,
        terms: terms
      }
    end

    # Also load most recent ComplianceMapping records to show resolve_map history
    recent_mappings = ComplianceMapping.where(project_id: project.id)
      .order(applied_at: :desc)
      .to_a
      .group_by(&:field_group_id)

    recent_mappings.each do |fg_id, mappings|
      latest = mappings.first
      prefill[fg_id] ||= { source_annot_id: nil, source_annot_name: nil, terms: [] }
      prefill[fg_id][:last_mapping] = {
        action_type: latest.action_type,
        source_path: latest.source_path,
        resolve_map: latest.resolve_map,
        applied_at: latest.applied_at
      }
    end

    prefill
  end

  # Write a constant value to all cells of a col_attr field using Python/h5py
  def write_constant_to_loom(loom_path, field_path, value)
    field_name = field_path.sub(%r{\A/col_attrs/}, '')
    python_script = <<~PYTHON
      import h5py
      import numpy as np
      import sys

      loom_path = sys.argv[1]
      field_name = sys.argv[2]
      value = sys.argv[3]

      with h5py.File(loom_path, 'r+') as f:
          n_cells = f['matrix'].shape[1]
          path = 'col_attrs/' + field_name
          if path in f:
              del f[path]
          f.create_dataset(path, data=np.array([value] * n_cells, dtype=h5py.special_dtype(vlen=str)))

      print('OK')
    PYTHON

    run_python_in_container(python_script, loom_path, field_name, value)
  end

  # Write a global attribute to the loom file using Python/h5py
  def write_global_attr_to_loom(loom_path, field_path, value)
    attr_name = field_path.sub(%r{\A/attrs/}, '')
    python_script = <<~PYTHON
      import h5py
      import numpy as np
      import sys

      loom_path = sys.argv[1]
      attr_name = sys.argv[2]
      value = sys.argv[3]

      with h5py.File(loom_path, 'r+') as f:
          # Store as file-level attribute (LOOM spec)
          f.attrs[attr_name] = value
          # Also store as dataset under attrs/ group (ASAP convention)
          attrs_path = 'attrs/' + attr_name
          if attrs_path in f:
              del f[attrs_path]
          f.create_dataset(attrs_path, data=np.array([value], dtype=h5py.special_dtype(vlen=str)))

      print('OK')
    PYTHON

    run_python_in_container(python_script, loom_path, attr_name, value)
  end

  # Resolve paired values: read source data, apply a JSON mapping, write to target
  # The mapping translates each source value to a resolved counterpart
  # (e.g., cell type name -> ontology term ID, or vice versa)
  def resolve_paired_in_loom(loom_path, source_path, target_path, resolve_map_json)
    source_field = source_path.start_with?('/') ? source_path[1..] : source_path
    target_field = target_path.start_with?('/') ? target_path[1..] : target_path

    python_script = <<~PYTHON
      import h5py
      import numpy as np
      import json
      import sys

      loom_path = sys.argv[1]
      source = sys.argv[2]
      target = sys.argv[3]
      resolve_map = json.loads(sys.argv[4])

      with h5py.File(loom_path, 'r+') as f:
          if source not in f:
              print('ERROR: Source path not found: ' + source, file=sys.stderr)
              sys.exit(1)
          src_data = f[source][:]
          # Decode bytes to strings if needed
          if src_data.dtype.kind in ('S', 'O'):
              src_data = np.array([v.decode('utf-8') if isinstance(v, bytes) else str(v) for v in src_data])
          else:
              src_data = np.array([str(v) for v in src_data])
          # Apply the mapping: for each source value, look up the resolved value
          resolved = []
          for val in src_data:
              mapped = resolve_map.get(val, val)
              resolved.append(mapped)
          resolved_arr = np.array(resolved, dtype=h5py.special_dtype(vlen=str))
          if target in f:
              del f[target]
          f.create_dataset(target, data=resolved_arr)

      print('OK')
    PYTHON

    run_python_in_container(python_script, loom_path, source_field, target_field, resolve_map_json)
  end

  # Adjust source_path if the source field was versioned earlier in the same batch.
  # Returns the versioned path if found, otherwise the original source_path.
  def adjust_source_if_versioned(source_path, versioned_paths)
    return source_path if source_path.blank?
    versioned_paths[source_path] || source_path
  end

  # Archive an existing metadata field under a versioned name (.v{N}), write new
  # data in its place, and create a proper Annot record for the replacement.
  #
  # This single function replaces the old backup_existing_metadata +
  # rename_annot_and_references + ensure_annot_record chain.  It is idempotent
  # within one batch thanks to the +versioned_paths+ hash that tracks which
  # fields have already been archived.
  #
  # Parameters:
  #   project          - the Project record
  #   loom_path        - absolute path to the LOOM file on disk
  #   field_path       - canonical HDF5 path (e.g. "/col_attrs/tissue")
  #   versioned_paths  - mutable Hash { original_path => archive_path } tracking
  #                      fields archived in this batch (updated in place)
  #   rename_annot     - when true (default), update Annot records and Run JSON
  #                      references; set to false for variant LOOM files where
  #                      the DB was already updated when the main file was processed
  #
  # Yields |loom_path, field_path| so the caller can write the new data.
  #
  # Returns the new Annot record, or nil if creation was skipped / failed.
  # +expected_archive_paths+ is an optional hash from the main-file pass that
  # maps { field_path => archive_path }.  When processing variant LOOMs
  # (rename_annot: false) we must use the same .v{N} archive names that the
  # main pass chose, because by the time variants are processed the DB already
  # reflects the new Annot (latest_version: true, version_nber: N+1).
  def version_and_replace_metadata(project, loom_path, field_path, versioned_paths, rename_annot: true, expected_archive_paths: {})
    relative_path = loom_path.sub(%r{\A.*/#{project.user_id}/#{project.key}/}, '')

    # -- Step A: determine version number and archive path --
    field_exists_in_loom = metadata_exists_in_loom?(loom_path, field_path)

    if expected_archive_paths[field_path]
      # Variant pass: reuse the archive path determined during main-file processing
      archive_path = expected_archive_paths[field_path]
      # Extract version from archive path (e.g. "/col_attrs/tissue.v1" -> 1)
      current_version = archive_path[/\.v(\d+)\z/, 1].to_i
      next_version = current_version + 1
    else
      # Main pass: look up current Annot to determine version
      current_annot = project.annots.find_by(name: field_path, latest_version: true)
    end

    if current_annot || field_exists_in_loom || expected_archive_paths[field_path]
      unless archive_path
        current_version = current_annot&.version_nber || 0
        next_version = current_version + 1
        archive_path = "#{field_path}.v#{current_version}"
      end

      # -- Step B: archive the old field in the LOOM --
      unless versioned_paths[field_path]
        if field_exists_in_loom
          rename_metadata_in_loom(loom_path, field_path, archive_path)
          Rails.logger.info("[Compliance Fix] Archived #{field_path} -> #{archive_path} in LOOM")
        end
        versioned_paths[field_path] = archive_path
      else
        archive_path = versioned_paths[field_path]
      end

      # -- Step C: update old Annot record and references (main file only) --
      if rename_annot && current_annot
        current_annot.update!(
          name: archive_path,
          label: archive_path.split('/').last,
          latest_version: false
        )
        Rails.logger.info("[Compliance Fix] Archived Annot ##{current_annot.id}: #{field_path} -> #{archive_path}")

        # Update Run DB columns that store annotation paths as strings
        update_run_attrs_json(project, field_path, archive_path)
        update_run_output_json(project, field_path, archive_path)

        # Update on-disk JSON files in the project directory that list metadata paths
        update_project_json_files(project, field_path, archive_path)

        # Update ComplianceMapping.source_path references if any point to old path
        ComplianceMapping.where(project_id: project.id, source_path: field_path)
                         .update_all(source_path: archive_path)
      end
    else
      # Brand new field (no existing Annot, not in LOOM)
      next_version = 1
    end

    # -- Step D: write new data to the LOOM --
    yield(loom_path, field_path) if block_given?

    # -- Step E: create the new Annot record (main file only) --
    if rename_annot
      dim = if field_path.start_with?('/col_attrs/')
              1
            elsif field_path.start_with?('/row_attrs/')
              2
            else
              4
            end
      data_type_id = (dim == 4) ? (DataType.find_by(name: 'STRING')&.id || 2) : (DataType.find_by(name: 'DISCRETE')&.id || 3)

      new_annot = project.annots.create!(
        name: field_path,
        filepath: relative_path,
        label: field_path.split('/').last,
        dim: dim,
        data_type_id: data_type_id,
        nber_cols: project.nber_cols,
        version_nber: next_version,
        latest_version: true,
        user_id: project.user_id
      )
      Rails.logger.info("[Compliance Fix] Created Annot ##{new_annot.id} for #{field_path} (v#{next_version})")
      return new_annot
    end

    nil
  rescue StandardError => e
    Rails.logger.error("[Compliance Fix] Error in version_and_replace_metadata for #{field_path}: #{e.message}")
    nil
  end

  # Rename (move) an existing metadata field in the loom file.
  # Used to back up existing data before overwriting (e.g., tissue -> tissue_original).
  def rename_metadata_in_loom(loom_path, old_path, new_path)
    old_field = old_path.start_with?('/') ? old_path[1..] : old_path
    new_field = new_path.start_with?('/') ? new_path[1..] : new_path

    python_script = <<~PYTHON
      import h5py
      import sys

      loom_path = sys.argv[1]
      old_name = sys.argv[2]
      new_name = sys.argv[3]

      with h5py.File(loom_path, 'r+') as f:
          if old_name not in f:
              print('SKIP: Source path not found: ' + old_name)
              sys.exit(0)
          if new_name in f:
              del f[new_name]
          f[new_name] = f[old_name][:]
          del f[old_name]

      print('OK')
    PYTHON

    run_python_in_container(python_script, loom_path, old_field, new_field)
  end

  # Check if a metadata field exists in the loom file
  def metadata_exists_in_loom?(loom_path, field_path)
    field = field_path.start_with?('/') ? field_path[1..] : field_path

    python_script = <<~PYTHON
      import h5py
      import sys

      loom_path = sys.argv[1]
      field = sys.argv[2]

      with h5py.File(loom_path, 'r') as f:
          if field in f:
              print('EXISTS')
          else:
              print('NOT_FOUND')
    PYTHON

    container = ENV.fetch('ASAP_RUN_CONTAINER', 'asap_run')
    cmd_parts = ['docker', 'exec', '-i', container, 'python3', '-', loom_path, field]

    begin
      stdout, _stderr, status = Open3.capture3(*cmd_parts, stdin_data: python_script)
      status.success? && stdout.strip == 'EXISTS'
    rescue StandardError => e
      Rails.logger.error("[Compliance Fix] Error checking metadata existence: #{e.message}")
      false
    end
  end

  # Find runs for this project whose attrs_json contains the old annotation
  # name (stored in the output_dataset field) and replace it with new_name.
  def update_run_attrs_json(project, old_name, new_name)
    runs = Run.where(project_id: project.id)
              .where("attrs_json LIKE ?", "%#{old_name}%")

    runs.find_each do |run|
      begin
        attrs = JSON.parse(run.attrs_json)
        changed = false
        attrs.each do |_key, val|
          next unless val.is_a?(Hash) && val['output_dataset'] == old_name
          val['output_dataset'] = new_name
          changed = true
        end
        if changed
          run.update!(attrs_json: attrs.to_json)
          Rails.logger.info("[Compliance Fix] Updated attrs_json for Run ##{run.id}: #{old_name} -> #{new_name}")
        end
      rescue StandardError => e
        Rails.logger.error("[Compliance Fix] Error updating attrs_json for Run ##{run.id}: #{e.message}")
      end
    end
  end

  # Find runs for this project whose output_json contains the old annotation
  # name and replace all occurrences with new_name.
  def update_run_output_json(project, old_name, new_name)
    runs = Run.where(project_id: project.id)
              .where("output_json LIKE ?", "%#{old_name}%")

    runs.find_each do |run|
      begin
        raw = run.output_json
        if raw.include?(old_name)
          updated = raw.gsub(old_name, new_name)
          run.update!(output_json: updated)
          Rails.logger.info("[Compliance Fix] Updated output_json for Run ##{run.id}: #{old_name} -> #{new_name}")
        end
      rescue StandardError => e
        Rails.logger.error("[Compliance Fix] Error updating output_json for Run ##{run.id}: #{e.message}")
      end
    end
  end

  # Update on-disk JSON files in the project directory that reference the old
  # annotation path.  Three file types are handled:
  #
  # 1. output.json (in each step/run dir) -- "metadata" array where each entry
  #    has a "name" field (e.g. "/col_attrs/tissue").
  # 2. list_metadata_to_copy.json  -- { "meta": ["/col_attrs/tissue", ...] }
  # 3. list_metadata_to_copy2.json -- same structure as above
  def update_project_json_files(project, old_path, new_path)
    project_dir = File.join(
      ENV.fetch('USER_DATA_DIR', '/data/asap2/projects'),
      project.user_id.to_s,
      project.key
    )
    return unless File.directory?(project_dir)

    # -- output.json files: update "name" inside the "metadata" array --
    Dir.glob(File.join(project_dir, '**', 'output.json')).each do |json_path|
      update_metadata_name_in_json(json_path, old_path, new_path)
    end

    # -- list_metadata_to_copy*.json files: update path strings in the "meta" array --
    Dir.glob(File.join(project_dir, '**', 'list_metadata_to_copy*.json')).each do |json_path|
      update_meta_list_in_json(json_path, old_path, new_path)
    end
  rescue StandardError => e
    Rails.logger.error("[Compliance Fix] Error updating project JSON files: #{e.message}")
  end

  # Replace old_path with new_path in the "metadata" array entries of an output.json file.
  # Each entry is a hash with a "name" key holding the annotation path.
  def update_metadata_name_in_json(json_path, old_path, new_path)
    raw = File.read(json_path)
    return unless raw.include?(old_path)

    data = JSON.parse(raw)
    changed = false

    if data.is_a?(Hash) && data['metadata'].is_a?(Array)
      data['metadata'].each do |entry|
        next unless entry.is_a?(Hash) && entry['name'] == old_path
        entry['name'] = new_path
        changed = true
      end
    end

    if changed
      File.write(json_path, JSON.pretty_generate(data))
      Rails.logger.info("[Compliance Fix] Updated #{json_path}: #{old_path} -> #{new_path}")
    end
  rescue StandardError => e
    Rails.logger.error("[Compliance Fix] Error updating #{json_path}: #{e.message}")
  end

  # Replace old_path with new_path in the "meta" array of a list_metadata_to_copy*.json file.
  # The array contains bare path strings (e.g. "/col_attrs/tissue").
  def update_meta_list_in_json(json_path, old_path, new_path)
    raw = File.read(json_path)
    return unless raw.include?(old_path)

    data = JSON.parse(raw)
    changed = false

    if data.is_a?(Hash) && data['meta'].is_a?(Array)
      data['meta'] = data['meta'].map do |entry|
        if entry == old_path
          changed = true
          new_path
        else
          entry
        end
      end
    end

    if changed
      File.write(json_path, JSON.generate(data))
      Rails.logger.info("[Compliance Fix] Updated #{json_path}: #{old_path} -> #{new_path}")
    end
  rescue StandardError => e
    Rails.logger.error("[Compliance Fix] Error updating #{json_path}: #{e.message}")
  end

  # Copy metadata from one path to another within the same loom file
  def copy_metadata_in_loom(loom_path, source_path, target_path)
    source_field = source_path.start_with?('/') ? source_path[1..] : source_path
    target_field = target_path.start_with?('/') ? target_path[1..] : target_path

    python_script = <<~PYTHON
      import h5py
      import numpy as np
      import sys

      loom_path = sys.argv[1]
      source = sys.argv[2]
      target = sys.argv[3]

      with h5py.File(loom_path, 'r+') as f:
          if source not in f:
              print('ERROR: Source path not found: ' + source, file=sys.stderr)
              sys.exit(1)
          data = f[source][:]
          if target in f:
              del f[target]
          f.create_dataset(target, data=data)

      print('OK')
    PYTHON

    run_python_in_container(python_script, loom_path, source_field, target_field)
  end

  # Execute a Python script inside the ASAP run container via stdin
  def run_python_in_container(script, *args)
    container = ENV.fetch('ASAP_RUN_CONTAINER', 'asap_run')
    cmd_parts = ['docker', 'exec', '-i', container, 'python3', '-'] + args

    begin
      stdout, stderr, status = Open3.capture3(*cmd_parts, stdin_data: script)

      unless status.success?
        Rails.logger.error("[Compliance Fix] Python script failed: #{stderr}")
        return false
      end

      stdout.strip.start_with?('OK')
    rescue StandardError => e
      Rails.logger.error("[Compliance Fix] Error running Python: #{e.message}")
      false
    end
  end

  # Record compliance mappings for tracking how scFAIR/CELLxGENE metadata vectors were generated.
  # Each applied fix is recorded with its action type, source, and resolve map.
  def record_compliance_mappings(project, applied, fixes)
    now = Time.current

    # Identify which field_group each applied field_path belongs to
    field_group_map = {}
    load_field_groups.each do |fg|
      field_group_map[fg[:term_path]] = fg[:id] if fg[:term_path]
      field_group_map[fg[:label_path]] = fg[:id] if fg[:label_path]
    end

    applied.each do |entry|
      field_path = entry[:field]
      field_group_id = field_group_map[field_path]
      next unless field_group_id

      fix_data = fixes[field_path] || {}
      action_type = entry[:action]
      action_type = 'map_from' if action_type == 'mapped'

      # Find the source annot if available
      source_path = entry[:source] || fix_data[:source].to_s
      source_annot = source_path.present? ? Annot.find_by(project_id: project.id, name: source_path) : nil

      mapping = ComplianceMapping.create!(
        project_id: project.id,
        field_group_id: field_group_id,
        target_path: field_path,
        action_type: action_type,
        source_annot_id: source_annot&.id,
        source_path: source_path.presence,
        set_value: entry[:value],
        resolve_map_json: fix_data[:resolve_map].to_s.presence,
        applied_at: now
      )

      # Record individual term replacements from the resolve map
      if action_type == 'resolve_paired' && fix_data[:resolve_map].present?
        resolve_map = begin
          JSON.parse(fix_data[:resolve_map])
        rescue JSON::ParserError
          {}
        end

        resolve_map.each do |original_value, replacement_value|
          # Determine if the replacement is an identifier or a name based on the target path
          is_term_id_path = field_path.include?('ontology_term_id')

          # Handle multi-term values (|| separated) by recording each sub-term individually
          replacement_parts = replacement_value.to_s.include?(' || ') ? replacement_value.split(' || ').map(&:strip) : [replacement_value]

          replacement_parts.each do |part|
            replacement_identifier = is_term_id_path ? part : nil
            replacement_name = is_term_id_path ? nil : part

            # Try to find the cell_ontology_term record
            cot = nil
            if replacement_identifier
              cot = CellOntologyTerm.find_by(identifier: replacement_identifier, original: true)
            elsif replacement_name
              cot = CellOntologyTerm.where(original: true).where('name ILIKE ?', replacement_name).first
            end

            ComplianceTermReplacement.create!(
              compliance_mapping_id: mapping.id,
              original_value: original_value,
              replacement_identifier: cot&.identifier || replacement_identifier,
              replacement_name: cot&.name || replacement_name,
              cell_ontology_term_id: cot&.id
            )
          end
        end
      end
    rescue StandardError => e
      Rails.logger.error("[Compliance Mapping] Error recording mapping for #{entry[:field]}: #{e.message}")
    end
  end

  # Ensure an Annot record exists for a metadata field.
  # Always sets dim and data_type_id so the record is usable across the app.
  def ensure_annot_record(project, field_path, loom_path)
    relative_path = loom_path.sub(%r{\A.*/#{project.user_id}/#{project.key}/}, '')
    existing = project.annots.find_by(name: field_path, filepath: relative_path)
    return existing if existing

    dim = if field_path.start_with?('/col_attrs/')
            1
          elsif field_path.start_with?('/row_attrs/')
            2
          else
            4
          end
    data_type_id = (dim == 4) ? (DataType.find_by(name: 'STRING')&.id || 2) : (DataType.find_by(name: 'DISCRETE')&.id || 3)

    project.annots.create(
      name: field_path,
      filepath: relative_path,
      label: field_path.split('/').last,
      dim: dim,
      data_type_id: data_type_id,
      nber_cols: project.nber_cols,
      user_id: project.user_id
    )
  rescue StandardError => e
    Rails.logger.error("[Compliance Fix] Could not create Annot record: #{e.message}")
  end
end
