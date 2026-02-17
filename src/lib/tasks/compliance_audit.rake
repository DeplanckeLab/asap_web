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

  desc "Reset a project to its pre-compliance-fix state: restore original LOOM files, " \
       "remove versioned Annots, reset version numbers, clear compliance mappings, " \
       "and restore Run JSON references. " \
       "Usage: rake compliance:reset_project PROJECT_ID=9595 ORIGINAL_DIR=/data/asap2/users"
  task reset_project: :environment do
    project_id  = ENV['PROJECT_ID']
    original_dir = ENV['ORIGINAL_DIR']

    abort "PROJECT_ID is required" if project_id.blank?
    abort "ORIGINAL_DIR is required (base users dir, e.g. /data/asap2/users)" if original_dir.blank?

    project = Project.find(project_id)
    test_data_dir = ENV.fetch('USER_DATA_DIR', '/data/asap2/projects')
    project_rel   = File.join(project.user_id.to_s, project.key)
    original_project_dir = File.join(original_dir, project_rel)
    test_project_dir     = File.join(test_data_dir, project_rel)

    abort "Original directory not found: #{original_project_dir}" unless File.directory?(original_project_dir)
    abort "Test directory not found: #{test_project_dir}" unless File.directory?(test_project_dir)

    puts "Resetting project ##{project.id} (#{project.key}) ..."
    puts "  Original: #{original_project_dir}"
    puts "  Test:     #{test_project_dir}"
    puts ""

    # -- Step 1: Restore LOOM and JSON files from originals --
    files_to_restore = %w[
      parsing/output.loom
      parsing/output.json
      parsing/list_metadata_to_copy.json
      parsing/list_metadata_to_copy2.json
    ]

    files_to_restore.each do |rel|
      src = File.join(original_project_dir, rel)
      dst = File.join(test_project_dir, rel)
      if File.exist?(src)
        FileUtils.cp(src, dst)
        puts "  Restored #{rel} (#{(File.size(dst) / 1_048_576.0).round(1)} MB)"
      else
        puts "  Skipped #{rel} (not found in original)"
      end
    end

    # -- Step 2: Identify versioned and compliance-created Annots --
    versioned_annots = project.annots.where("name LIKE ?", "%.v%")
    compliance_annots = project.annots.where("version_nber > 1 AND latest_version = true")

    puts ""
    puts "  Versioned annots (.vX): #{versioned_annots.count}"
    versioned_annots.each { |a| puts "    ##{a.id} #{a.name} (v#{a.version_nber})" }
    puts "  Compliance-created annots (v>1): #{compliance_annots.count}"
    compliance_annots.each { |a| puts "    ##{a.id} #{a.name} (v#{a.version_nber})" }

    # -- Step 3: Restore original Annots as canonical --
    # For each .vX annot, check if it was the original (v1) and if the base
    # name no longer has a latest record after we delete the compliance ones.
    originals_to_restore = []
    versioned_annots.where(version_nber: 1).each do |a|
      base_name = a.name.sub(/\.v\d+\z/, '')
      originals_to_restore << { annot: a, base_name: base_name }
    end

    originals_to_restore.each do |entry|
      a = entry[:annot]
      a.update_columns(name: entry[:base_name], label: entry[:base_name].split('/').last, latest_version: true, version_nber: 1)
      puts "  Restored annot ##{a.id}: #{entry[:base_name]}"
    end

    # -- Step 4: Delete compliance artifacts (correct FK order) --
    mapping_ids = ComplianceMapping.where(project_id: project.id).pluck(:id)
    if mapping_ids.any?
      ActiveRecord::Base.connection.execute(
        "DELETE FROM compliance_term_replacements WHERE compliance_mapping_id IN (#{mapping_ids.join(',')})"
      )
      ComplianceMapping.where(project_id: project.id).delete_all
      puts "  Deleted #{mapping_ids.size} compliance mappings (+ term replacements)"
    end

    # Delete compliance-created annots and remaining .vX backups
    ids_to_delete = (compliance_annots.pluck(:id) + versioned_annots.where("version_nber > 1").pluck(:id)).uniq
    if ids_to_delete.any?
      ActiveRecord::Base.connection.execute("DELETE FROM annots WHERE id IN (#{ids_to_delete.join(',')})")
      puts "  Deleted #{ids_to_delete.size} compliance annots"
    end

    # -- Step 5: Reset all version numbers --
    updated = project.annots.where("version_nber IS NULL OR version_nber != 1").update_all(version_nber: 1)
    puts "  Reset version_nber to 1 for #{updated} annots" if updated > 0

    # -- Step 6: Restore Run JSON references --
    # Find runs whose attrs_json or output_json contain .vN paths and revert them.
    Run.where(project_id: project.id).where("attrs_json LIKE ?", "%.v%").find_each do |run|
      original_json = run.attrs_json
      cleaned = original_json.gsub(%r{(/col_attrs/[a-z_]+)\.v\d+}, '\1')
                             .gsub(%r{(/row_attrs/[a-z_]+)\.v\d+}, '\1')
                             .gsub(%r{(/attrs/[a-z_]+)\.v\d+}, '\1')
      if cleaned != original_json
        run.update_columns(attrs_json: cleaned)
        puts "  Restored attrs_json for Run ##{run.id}"
      end
    end
    Run.where(project_id: project.id).where("output_json LIKE ?", "%.v%").find_each do |run|
      original_json = run.output_json
      cleaned = original_json.gsub(%r{(/col_attrs/[a-z_]+)\.v\d+}, '\1')
                             .gsub(%r{(/row_attrs/[a-z_]+)\.v\d+}, '\1')
                             .gsub(%r{(/attrs/[a-z_]+)\.v\d+}, '\1')
      if cleaned != original_json
        run.update_columns(output_json: cleaned)
        puts "  Restored output_json for Run ##{run.id}"
      end
    end

    # -- Step 7: Delete Annots that don't exist in the actual LOOM file --
    # The compliance fix may have created brand-new Annot records for fields
    # that were not in the original LOOM. These have version_nber=1 so they
    # are not caught by the versioned-annot cleanup above.
    loom_path = File.join(test_project_dir, 'parsing', 'output.loom')
    if File.exist?(loom_path)
      require 'open3'
      python_script = <<~PY
        import h5py, json, sys
        f = h5py.File(sys.argv[1], 'r')
        paths = []
        for group, prefix in [('/col_attrs', '/col_attrs/'), ('/row_attrs', '/row_attrs/'),
                               ('/attrs', '/attrs/'), ('/layers', '/layers/')]:
            if group in f:
                for k in f[group].keys():
                    paths.append(prefix + k)
        if '/matrix' in f:
            paths.append('/matrix')
        f.close()
        print(json.dumps(paths))
      PY

      container = ENV.fetch('ASAP_RUN_CONTAINER', 'asap_run')
      stdout, stderr, status = Open3.capture3(
        'docker', 'exec', '-i', container, 'python3', '-c', python_script,
        loom_path
      )

      if status.success?
        loom_field_set = JSON.parse(stdout.strip).to_set
        orphans = project.annots.reject { |a| loom_field_set.include?(a.name) }

        if orphans.any?
          orphan_ids = orphans.map(&:id)
          ActiveRecord::Base.connection.execute(
            "DELETE FROM annots WHERE id IN (#{orphan_ids.join(',')})"
          )
          puts "  Deleted #{orphan_ids.size} orphan Annots not present in LOOM:"
          orphans.each { |a| puts "    #{a.name}" }
        else
          puts "  No orphan Annots found (all match LOOM content)"
        end
      else
        puts "  WARNING: Could not read LOOM structure to check orphan Annots: #{stderr.strip}"
      end
    end

    # -- Step 8: Delete cached validation result --
    vpath = File.join(test_project_dir, 'cxg_validation_result.json')
    if File.exist?(vpath)
      File.delete(vpath)
      puts "  Deleted cached validation result"
    end

    puts ""
    puts "Project ##{project.id} reset complete."

    # -- Summary verification --
    vx_count = project.annots.where("name LIKE ?", "%.v%").count
    high_v   = project.annots.where("version_nber > 1").count
    cm_count = ComplianceMapping.where(project_id: project.id).count
    total_annots = project.annots.count
    puts "  Verification: total annots=#{total_annots}, .vX annots=#{vx_count}, v>1 annots=#{high_v}, mappings=#{cm_count}"
  end
end
