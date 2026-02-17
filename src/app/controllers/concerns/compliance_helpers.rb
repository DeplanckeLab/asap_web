# frozen_string_literal: true

require 'open3'

# Shared helpers for loading compliance validation data.
# Included by ComplianceController and ProjectsController.
module ComplianceHelpers
  extend ActiveSupport::Concern

  private

  # Load the validation result for a project, trying multiple storage locations.
  # Returns a Hash with symbolized keys, or nil.
  def load_validation_result(project)
    if project.respond_to?(:cxg_validation_result)
      result = project.cxg_validation_result
      return result.deep_symbolize_keys if result.present?
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

  # Find the primary loom file for validation (parsing/output.loom)
  def find_project_loom_path(project)
    return nil unless project.respond_to?(:key) && project.respond_to?(:user_id)
    return nil unless project.key.present? && project.user_id.present?

    user_data_dir = ENV.fetch('USER_DATA_DIR', '/data/asap2/projects')

    parsing_output = File.join(user_data_dir, project.user_id.to_s, project.key, 'parsing', 'output.loom')
    return parsing_output if File.exist?(parsing_output)

    project_dir = File.join(user_data_dir, project.user_id.to_s, project.key)
    if File.directory?(project_dir)
      loom_files = Dir.glob(File.join(project_dir, '**', '*.loom'))
      return loom_files.first if loom_files.any?
    end

    nil
  end

  # Read unique values (and optional co-occurrence pairs) from a LOOM file.
  # Returns { field_path => [unique_values], "tp||lp" => [[term, label], ...] }
  def batch_read_field_values(loom_path, field_paths, paired_paths: [])
    return {} if field_paths.blank? || loom_path.blank?

    container = ENV.fetch('ASAP_RUN_CONTAINER', 'asap_run')
    fields_json = field_paths.to_json
    pairs_json = paired_paths.to_json

    script = <<~PY
      import h5py, sys, json

      def decode(v):
          return v.decode() if hasattr(v, 'decode') else str(v)

      f = h5py.File(sys.argv[1], 'r')
      fields = json.loads(sys.argv[2])
      pairs = json.loads(sys.argv[3])
      result = {}

      for fp in fields:
          parts = fp.lstrip('/').split('/')
          try:
              ds = f
              for p in parts:
                  ds = ds[p]
              vals = ds[:]
              unique = sorted(set(decode(v) for v in vals))
              result[fp] = unique
          except Exception:
              result[fp] = []

      for term_fp, label_fp in pairs:
          tp = term_fp.lstrip('/').split('/')
          lp = label_fp.lstrip('/').split('/')
          try:
              tds = f
              for p in tp:
                  tds = tds[p]
              lds = f
              for p in lp:
                  lds = lds[p]
              tvals = tds[:]
              lvals = lds[:]
              seen = set()
              ordered_pairs = []
              for tv, lv in zip(tvals, lvals):
                  tv_s = decode(tv)
                  lv_s = decode(lv)
                  key = (tv_s, lv_s)
                  if key not in seen:
                      seen.add(key)
                      ordered_pairs.append([tv_s, lv_s])
              ordered_pairs.sort(key=lambda x: x[1])
              result[term_fp + '||' + label_fp] = ordered_pairs
          except Exception:
              pass

      f.close()
      print(json.dumps(result))
    PY

    stdout, _stderr, status = Open3.capture3(
      'docker', 'exec', container, 'python3', '-c', script, loom_path, fields_json, pairs_json
    )
    return {} unless status.success?

    JSON.parse(stdout) rescue {}
  end

  # Resolve field values against the ontology database.
  # Returns a hash of { path => { value => true/false } } where true means
  # the value is a valid ontology term (or allowed free-text value).
  def resolve_field_values(groups, raw_values)
    result = {}

    allowed_specials = CxgLoomValidatorService::ALLOWED_SPECIAL_VALUES rescue {}

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

      next if prefixes.blank?

      ontology_ids = CellOntology.where(tag: prefixes).pluck(:id)
      next if ontology_ids.empty?

      scope = CellOntologyTerm.where(original: true, cell_ontology_id: ontology_ids)

      # Build a set of allowed free-text values for this field
      free_text_set = Set.new
      specials = allowed_specials[g[:term_path]]
      free_text_set.merge(specials) if specials
      if g[:id].present?
        ott = OntologyTermType.find_by(field_group_id: g[:id])
        free_text_set.merge(ott.free_text_entries.map { |e| e.is_a?(Hash) ? e['value'].to_s : e.to_s }) if ott
      end

      # Resolve term path (identifiers like CL:0000540)
      term_vals = raw_values[g[:term_path]] || []
      if term_vals.any?
        all_sub_terms = Set.new
        term_vals.each { |v| v.to_s.split(' || ').each { |t| all_sub_terms << t.strip } }
        all_sub_terms.reject!(&:blank?)

        ontology_sub_terms = all_sub_terms.reject { |t| free_text_set.include?(t) }
        known_ids = ontology_sub_terms.any? ? scope.where(identifier: ontology_sub_terms.to_a).pluck(:identifier).to_set : Set.new
        known_ids.merge(free_text_set)

        result[g[:term_path]] = term_vals.index_with do |v|
          parts = v.to_s.split(' || ').map(&:strip).reject(&:blank?)
          parts.all? { |p| known_ids.include?(p) }
        end
      end

      # Resolve label path (names like "neuron", "fat body")
      if g[:label_path].present?
        label_vals = raw_values[g[:label_path]] || []
        if label_vals.any?
          all_sub_names = Set.new
          label_vals.each { |v| v.to_s.split(' || ').each { |t| all_sub_names << t.strip } }
          all_sub_names.reject!(&:blank?)

          ontology_sub_names = all_sub_names.reject { |t| free_text_set.include?(t) }
          exact_names = Set.new
          exact_names.merge(free_text_set)
          mappable_names = Set.new
          if ontology_sub_names.any?
            lower_map = {}
            ontology_sub_names.each { |n| lower_map[n.downcase] = n }
            scope.where('LOWER(name) IN (?)', lower_map.keys)
                 .pluck(:name).each { |n| exact_names << lower_map[n.downcase] if lower_map[n.downcase] }

            # Retry unresolved names with underscores replaced by spaces
            remaining = ontology_sub_names.reject { |n| exact_names.include?(n) }
            if remaining.any?
              space_map = {}
              remaining.select { |n| n.include?('_') }.each { |n| space_map[n.tr('_', ' ').downcase] = n }
              if space_map.any?
                scope.where('LOWER(name) IN (?)', space_map.keys)
                     .pluck(:name).each { |n| mappable_names << space_map[n.downcase] if space_map[n.downcase] }
              end
            end
          end

          result[g[:label_path]] = label_vals.index_with do |v|
            parts = v.to_s.split(' || ').map(&:strip).reject(&:blank?)
            if parts.all? { |p| exact_names.include?(p) }
              true
            elsif parts.all? { |p| exact_names.include?(p) || mappable_names.include?(p) }
              'mappable'
            else
              false
            end
          end
        end
      end
    end

    result
  end
end
