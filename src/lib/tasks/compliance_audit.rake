require 'json'

namespace :compliance do
  desc "Audit all projects for Annot records with scFAIR canonical names whose content is not compliant. " \
       "Reports which projects have non-compliant fields and whether those fields are used in runs. " \
       "Usage: rake compliance:audit_canonical_fields [PROJECT_ID=123] [LIMIT=100]"
  task audit_canonical_fields: :environment do
    project_id = ENV['PROJECT_ID']
    limit      = ENV['LIMIT']&.to_i

    # ── Load field definitions from the database ──

    co_id_to_tag = CellOntology.pluck(:id, :tag).to_h
    ontology_id_by_tag = co_id_to_tag.invert

    ontology_rules = {}
    enum_rules = {}
    label_rules = {}
    free_text_fields = []

    OntologyTermType.compliance_field_groups.each do |ott|
      fg = ott.to_field_group(co_id_to_tag)
      next if fg[:auto_from_project] # skip organism/title

      # Extract field name from term_path (e.g. "/col_attrs/tissue_ontology_term_id" -> "tissue_ontology_term_id")
      term_name = fg[:term_path].to_s.sub(%r{^/col_attrs/}, '').sub(%r{^/attrs/}, '')
      next if term_name.blank?

      prefixes = fg[:term_ontology_prefixes] || []
      valid_values = fg[:term_valid_values] || []

      if valid_values.any?
        # Enum field (tissue_type, suspension_type, is_primary_data)
        enum_rules[term_name] = valid_values
      elsif prefixes.any?
        # Ontology term ID field -- special accepted values depend on the field
        special = %w[unknown na]
        special = [] if %w[assay_ontology_term_id disease_ontology_term_id tissue_ontology_term_id].include?(term_name)
        ontology_rules[term_name] = { prefixes: prefixes, special: special }

        # Paired label field
        if fg[:label_path].present?
          label_name = fg[:label_path].to_s.sub(%r{^/col_attrs/}, '').sub(%r{^/attrs/}, '')
          label_special = special.dup
          label_special = %w[normal] if label_name == 'disease'
          label_rules[label_name] = { prefixes: prefixes, special: label_special }
        end
      else
        # Free text field (donor_id)
        free_text_fields << term_name
      end
    end

    label_fields = label_rules.keys

    # Build the full list of canonical col_attrs paths
    all_canonical_names = ontology_rules.keys + enum_rules.keys + label_fields + free_text_fields
    canonical_paths = all_canonical_names.map { |n| "/col_attrs/#{n}" }

    # Cache of known valid ontology term names per prefix set (to avoid repeated queries)
    # Key: frozen sorted prefix array, Value: Set of known valid names
    valid_names_cache = {}

    # ── Helper: check if a label value is a valid ontology term name ──
    check_label_name = lambda do |name, prefixes, special_values|
      name = name.to_s.strip
      return true if name.empty?
      return true if special_values.include?(name)

      # Handle || separated multi-names
      parts = name.include?(' || ') ? name.split(' || ').map(&:strip) : [name]
      parts.all? do |part|
        part = part.strip
        next true if part.empty?
        next true if special_values.include?(part)

        cache_key = prefixes.sort.freeze
        unless valid_names_cache.key?(cache_key)
          valid_names_cache[cache_key] = Set.new
        end
        cached = valid_names_cache[cache_key]

        if cached.include?(part)
          true
        else
          ontology_ids = prefixes.map { |p| ontology_id_by_tag[p] }.compact
          if ontology_ids.any?
            found = CellOntologyTerm.where(original: true, cell_ontology_id: ontology_ids, name: part).exists?
          else
            found = false
          end
          cached.add(part) if found
          found
        end
      end
    end

    # ── Helper: check if a single ontology term value is compliant ──
    check_ontology_term = lambda do |term, prefixes, special_values|
      term = term.to_s.strip
      return true if term.empty?
      return true if special_values.include?(term)
      return true if term.start_with?('CVCL_') && prefixes.include?('CVCL')

      parts = term.include?(' || ') ? term.split(' || ').map(&:strip) : [term]
      parts.all? do |part|
        part = part.strip
        next true if part.empty?
        next true if special_values.include?(part)
        next true if part.start_with?('CVCL_') && prefixes.include?('CVCL')
        next false unless part.match?(/\A[A-Za-z]+:\d+\z/)
        prefix = part.split(':').first
        prefixes.include?(prefix)
      end
    end

    # ── Query all Annot records with canonical scFAIR names ──
    # Only consider the latest version of each field (excludes archived .v{N} copies).
    scope = Annot.where(name: canonical_paths, latest_version: true)
    scope = scope.where(project_id: project_id) if project_id

    # Group by project
    annots_by_project = scope.includes(:project).group_by(&:project_id)

    if limit && !project_id
      annots_by_project = annots_by_project.first(limit).to_h
    end

    total_projects = annots_by_project.size
    projects_with_issues = 0
    total_non_compliant = 0
    total_used_in_runs = 0
    total_no_categories = 0
    all_issues = []

    puts "Found #{total_projects} project(s) with Annot records matching scFAIR canonical names."
    puts "=" * 110
    scanned = 0

    annots_by_project.each do |proj_id, annots|
      scanned += 1
      project = annots.first.project
      project_name = project&.respond_to?(:name) ? project.name.to_s.truncate(50) : 'unnamed'

      project_issues = []

      annots.each do |annot|
        field_name = annot.name.sub('/col_attrs/', '')

        # Parse categories from Annot record
        categories = nil
        if annot.categories_json.present?
          begin
            parsed = JSON.parse(annot.categories_json)
            categories = parsed.is_a?(Hash) ? parsed.keys : (parsed.is_a?(Array) ? parsed : nil)
          rescue JSON::ParserError
            categories = nil
          end
        end

        # Also try list_cat_json as alternative source of unique values
        if categories.nil? && annot.list_cat_json.present?
          begin
            categories = JSON.parse(annot.list_cat_json)
            categories = categories.is_a?(Array) ? categories : nil
          rescue JSON::ParserError
            categories = nil
          end
        end

        # ── Check ontology term ID fields ──
        if ontology_rules.key?(field_name)
          rule = ontology_rules[field_name]
          unless categories
            total_no_categories += 1
            next
          end

          non_compliant = categories.reject { |v| check_ontology_term.call(v, rule[:prefixes], rule[:special]) }
          if non_compliant.any?
            project_issues << {
              field: field_name,
              type: :ontology,
              annot_id: annot.id,
              total_unique: categories.size,
              non_compliant_count: non_compliant.size,
              sample_bad: non_compliant.first(5)
            }
          end

        # ── Check enum fields ──
        elsif enum_rules.key?(field_name)
          valid_values = enum_rules[field_name]
          unless categories
            total_no_categories += 1
            next
          end

          non_compliant = categories.reject { |v| v.to_s.strip.empty? || valid_values.include?(v.to_s.strip) }
          if non_compliant.any?
            project_issues << {
              field: field_name,
              type: :enum,
              annot_id: annot.id,
              total_unique: categories.size,
              non_compliant_count: non_compliant.size,
              sample_bad: non_compliant.first(5)
            }
          end

        # ── Label fields: check if values are exact ontology term names ──
        elsif label_rules.key?(field_name)
          rule = label_rules[field_name]
          unless categories
            total_no_categories += 1
            next
          end

          non_compliant = categories.reject { |v| check_label_name.call(v, rule[:prefixes], rule[:special]) }
          if non_compliant.any?
            project_issues << {
              field: field_name,
              type: :label,
              annot_id: annot.id,
              total_unique: categories.size,
              non_compliant_count: non_compliant.size,
              sample_bad: non_compliant.first(5)
            }
          end

        # ── Free text fields (donor_id): always compliant ──
        elsif free_text_fields.include?(field_name)
          next
        end
      end

      next if project_issues.empty?

      projects_with_issues += 1
      total_non_compliant += project_issues.size

      puts "[#{scanned}/#{total_projects}] Project ##{proj_id} (#{project_name})"

      # For each issue, check run/association usage
      project_issues.each do |issue|
        field_path = "/col_attrs/#{issue[:field]}"

        run_count = Run.where(project_id: proj_id)
                       .where("attrs_json LIKE ?", "%#{field_path}%").count
        cla_count = Cla.where(annot_id: issue[:annot_id]).count
        acs_count = AnnotCellSet.where(annot_id: issue[:annot_id]).count
        ot_count  = OtProject.where(annot_id: issue[:annot_id]).count

        used = run_count > 0 || cla_count > 0 || acs_count > 0 || ot_count > 0
        total_used_in_runs += 1 if used

        issue[:run_count] = run_count
        issue[:cla_count] = cla_count
        issue[:acs_count] = acs_count
        issue[:ot_count]  = ot_count
        issue[:used]      = used
        issue[:project_id] = proj_id
        issue[:project_name] = project_name

        all_issues << issue

        usage_parts = []
        usage_parts << "#{run_count} run(s)" if run_count > 0
        usage_parts << "#{cla_count} cla(s)" if cla_count > 0
        usage_parts << "#{acs_count} cell_set(s)" if acs_count > 0
        usage_parts << "#{ot_count} ot_project(s)" if ot_count > 0
        usage_str = usage_parts.any? ? "USED IN: #{usage_parts.join(', ')}" : "not used in runs"

        bad_str = issue[:non_compliant_count] ? "#{issue[:non_compliant_count]}/#{issue[:total_unique]}" : "?/#{issue[:total_unique]}"
        sample_str = issue[:sample_bad].any? ? issue[:sample_bad].map { |v| v.to_s.truncate(40) }.join(', ') : '-'

        puts "  #{issue[:field]} (#{issue[:type]}): #{bad_str} non-compliant -- #{usage_str}"
        puts "    Sample: #{sample_str}"
        puts "    #{issue[:note]}" if issue[:note]
      end
    end

    # ── Summary ──
    puts ""
    puts "=" * 110
    puts "AUDIT SUMMARY"
    puts "=" * 110
    puts "Projects with canonical scFAIR Annots: #{total_projects}"
    puts "Projects with non-compliant fields:    #{projects_with_issues}"
    puts "Total non-compliant fields:            #{total_non_compliant}"
    puts "Fields used in runs/associations:      #{total_used_in_runs}"
    puts "Fields without categories (unknown):   #{total_no_categories}"
    puts ""

    if all_issues.any?
      puts "DETAILED ISSUE LIST (#{all_issues.size} entries):"
      puts "-" * 110
      puts format("%-8s %-45s %-35s %-12s %-10s %-5s",
                   "Proj ID", "Project Name", "Field", "Type", "Bad/Total", "Used?")
      puts "-" * 110

      all_issues.each do |issue|
        bad_total = issue[:non_compliant_count] ? "#{issue[:non_compliant_count]}/#{issue[:total_unique]}" : "?/#{issue[:total_unique]}"
        puts format("%-8d %-45s %-35s %-12s %-10s %-5s",
                     issue[:project_id],
                     (issue[:project_name] || '').to_s.truncate(43),
                     issue[:field].truncate(33),
                     issue[:type],
                     bad_total,
                     issue[:used] ? "YES" : "no")
      end
    else
      puts "No issues found."
    end
  end
end
