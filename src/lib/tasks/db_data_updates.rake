namespace :db do
  desc "Apply database data updates from db/data_updates.yml"
  task apply_data_updates: :environment do
    updates_file = Rails.root.join('db', 'data_updates.yml')
    
    unless File.exist?(updates_file)
      puts "Updates file not found: #{updates_file}"
      puts "Create db/data_updates.yml with your updates"
      exit 1
    end
    
    require 'yaml'
    updates = YAML.load_file(updates_file)
    
    unless updates.is_a?(Array)
      puts "Error: data_updates.yml must contain an array of updates"
      exit 1
    end
    
    if updates.empty?
      puts "No updates found in data_updates.yml"
      exit 0
    end
    
    puts "Applying #{updates.count} database update(s)..."
    puts ""
    
    success_count = 0
    failed_count = 0
    skipped_count = 0
    
    updates.each_with_index do |update, index|
      model_name = update['model']
      find_by = update['find_by']
      updates_hash = update['updates']
      
      unless model_name && find_by && updates_hash
        puts "Update ##{index + 1}: Invalid format (missing model, find_by, or updates)"
        failed_count += 1
        next
      end
      
      begin
        model_class = model_name.constantize
        
        record = model_class.find_by(find_by)
        
        if record.nil?
          puts "Update ##{index + 1} (#{model_name}): Record not found with #{find_by.inspect}"
          skipped_count += 1
          next
        end
        
        # Check if update is needed
        needs_update = updates_hash.any? do |key, value|
          record.send(key) != value
        end
        
        unless needs_update
          puts "Update ##{index + 1} (#{model_name} ##{record.id}): No changes needed"
          skipped_count += 1
          next
        end
        
        # Apply updates
        if record.update(updates_hash)
          changed_fields = updates_hash.keys.select { |k| record.send("#{k}_changed?") rescue false }
          puts "Update ##{index + 1} (#{model_name} ##{record.id}): Updated #{changed_fields.join(', ')}"
          success_count += 1
        else
          puts "Update ##{index + 1} (#{model_name} ##{record.id}): Failed - #{record.errors.full_messages.join(', ')}"
          failed_count += 1
        end
        
      rescue NameError => e
        puts "Update ##{index + 1}: Model '#{model_name}' not found - #{e.message}"
        failed_count += 1
      rescue => e
        puts "Update ##{index + 1} (#{model_name}): Error - #{e.class}: #{e.message}"
        puts "  #{e.backtrace.first}" if e.backtrace
        failed_count += 1
      end
    end
    
    puts ""
    puts "Summary:"
    puts "  Success: #{success_count}"
    puts "  Failed:  #{failed_count}"
    puts "  Skipped: #{skipped_count}"
    puts "  Total:   #{updates.count}"
    
    exit 1 if failed_count > 0
  end
  
  desc "Show what updates would be applied (dry run)"
  task preview_data_updates: :environment do
    updates_file = Rails.root.join('db', 'data_updates.yml')
    
    unless File.exist?(updates_file)
      puts "Updates file not found: #{updates_file}"
      exit 1
    end
    
    require 'yaml'
    updates = YAML.load_file(updates_file)
    
    unless updates.is_a?(Array)
      puts "Error: data_updates.yml must contain an array of updates"
      exit 1
    end
    
    if updates.empty?
      puts "No updates found in data_updates.yml"
      exit 0
    end
    
    puts "Preview of #{updates.count} database update(s)..."
    puts ""
    
    updates.each_with_index do |update, index|
      model_name = update['model']
      find_by = update['find_by']
      updates_hash = update['updates']
      
      puts "Update ##{index + 1}:"
      puts "  Model: #{model_name}"
      puts "  Find by: #{find_by.inspect}"
      puts "  Updates: #{updates_hash.inspect}"
      
      begin
        model_class = model_name.constantize
        record = model_class.find_by(find_by)
        
        if record.nil?
          puts "  Status: RECORD NOT FOUND"
        else
          puts "  Status: Found record ##{record.id}"
          updates_hash.each do |key, new_value|
            current_value = record.send(key) rescue "N/A"
            if current_value != new_value
              puts "    #{key}: '#{current_value}' -> '#{new_value}'"
            else
              puts "    #{key}: '#{current_value}' (no change)"
            end
          end
        end
      rescue => e
        puts "  Status: ERROR - #{e.message}"
      end
      
      puts ""
    end
  end

  desc "Replace asap2_data_* references with asap_data_* across all public tables/columns"
  task replace_asap2_data_references: :environment do
    target_db = ENV.fetch('TARGET_DB', 'asap_production')
    dry_run = ENV['DRY_RUN'].to_s == '1'
    old_prefix = 'asap2_data_'
    new_prefix = 'asap_data_'

    connection = ActiveRecord::Base.connection
    current_db = connection.select_value('SELECT current_database()')

    if current_db != target_db
      puts "Error: connected to '#{current_db}', expected '#{target_db}'."
      puts "Run this task against the correct database or override TARGET_DB."
      exit 1
    end

    columns_sql = <<~SQL
      SELECT table_name, column_name, data_type, udt_name
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND (
          data_type IN ('text', 'character varying', 'character', 'json', 'jsonb')
          OR udt_name IN ('_text', '_varchar', '_bpchar')
        )
      ORDER BY table_name, ordinal_position;
    SQL

    columns = connection.exec_query(columns_sql).to_a
    if columns.empty?
      puts 'No eligible columns found in public schema.'
      exit 0
    end

    puts "Database: #{current_db}"
    puts "Mode: #{dry_run ? 'DRY RUN' : 'APPLY'}"
    puts "Columns scanned: #{columns.count}"
    puts ''

    touched_columns = 0
    touched_rows_total = 0
    errors = 0

    columns.each do |column|
      table_name = column['table_name']
      column_name = column['column_name']
      data_type = column['data_type']
      udt_name = column['udt_name']

      quoted_table = connection.quote_table_name(table_name)
      quoted_column = connection.quote_column_name(column_name)

      expression =
        case data_type
        when 'json'
          "(#{quoted_column})::text"
        when 'jsonb'
          "(#{quoted_column})::text"
        else
          quoted_column
        end

      where_sql = "#{expression} LIKE '%#{old_prefix}%'"
      count_sql = "SELECT COUNT(*) FROM #{quoted_table} WHERE #{where_sql}"
      match_count = connection.select_value(count_sql).to_i
      next if match_count.zero?

      touched_columns += 1
      touched_rows_total += match_count

      if dry_run
        puts "[DRY RUN] #{table_name}.#{column_name} (#{data_type}/#{udt_name}) -> #{match_count} row(s)"
        next
      end

      begin
        update_sql =
          case data_type
          when 'json'
            <<~SQL
              UPDATE #{quoted_table}
              SET #{quoted_column} = replace((#{quoted_column})::text, '#{old_prefix}', '#{new_prefix}')::json
              WHERE #{where_sql}
            SQL
          when 'jsonb'
            <<~SQL
              UPDATE #{quoted_table}
              SET #{quoted_column} = replace((#{quoted_column})::text, '#{old_prefix}', '#{new_prefix}')::jsonb
              WHERE #{where_sql}
            SQL
          when 'ARRAY'
            <<~SQL
              UPDATE #{quoted_table}
              SET #{quoted_column} = ARRAY(
                SELECT replace(elem, '#{old_prefix}', '#{new_prefix}')
                FROM unnest(#{quoted_column}) AS elem
              )
              WHERE #{where_sql}
            SQL
          else
            <<~SQL
              UPDATE #{quoted_table}
              SET #{quoted_column} = replace(#{quoted_column}, '#{old_prefix}', '#{new_prefix}')
              WHERE #{where_sql}
            SQL
          end

        result = connection.exec_update(update_sql, "replace_asap2_data_references_#{table_name}_#{column_name}")
        puts "[UPDATED] #{table_name}.#{column_name} (#{data_type}/#{udt_name}) -> #{result} row(s)"
      rescue StandardError => e
        errors += 1
        puts "[ERROR] #{table_name}.#{column_name} (#{data_type}/#{udt_name}) -> #{e.class}: #{e.message}"
      end
    end

    puts ''
    puts 'Summary:'
    puts "  Columns with matches: #{touched_columns}"
    puts "  Rows with matches:    #{touched_rows_total}"
    puts "  Errors:               #{errors}"

    unless dry_run
      remaining = 0
      columns.each do |column|
        table_name = column['table_name']
        column_name = column['column_name']
        data_type = column['data_type']
        quoted_table = connection.quote_table_name(table_name)
        quoted_column = connection.quote_column_name(column_name)

        expression =
          case data_type
          when 'json', 'jsonb'
            "(#{quoted_column})::text"
          else
            quoted_column
          end

        count_sql = "SELECT COUNT(*) FROM #{quoted_table} WHERE #{expression} LIKE '%#{old_prefix}%'"
        remaining += connection.select_value(count_sql).to_i
      end
      puts "  Remaining matches:    #{remaining}"
      exit 1 if errors.positive?
    end
  end
end

namespace :versions do
  desc "Set default CxG schema version (7.1.0) for all versions that don't have it set"
  task set_cxg_schema_version: :environment do
    default_version = ENV.fetch('CXG_VERSION', '7.1.0')
    
    puts "Setting cxg_schema_version to '#{default_version}' for versions that don't have it..."
    
    updated_count = 0
    skipped_count = 0
    error_count = 0
    
    Version.find_each do |version|
      begin
        env_data = Basic.safe_parse_json(version.env_json, {})
        
        if env_data['cxg_schema_version'].present?
          puts "  Version ##{version.id}: Already has cxg_schema_version='#{env_data['cxg_schema_version']}', skipping"
          skipped_count += 1
          next
        end
        
        env_data['cxg_schema_version'] = default_version
        version.update!(env_json: JSON.generate(env_data))
        
        puts "  Version ##{version.id}: Set cxg_schema_version='#{default_version}'"
        updated_count += 1
        
      rescue StandardError => e
        puts "  Version ##{version.id}: ERROR - #{e.message}"
        error_count += 1
      end
    end
    
    puts ""
    puts "Summary:"
    puts "  Updated: #{updated_count}"
    puts "  Skipped: #{skipped_count}"
    puts "  Errors:  #{error_count}"
    puts "  Total:   #{Version.count}"
  end

  desc "Migrate env_json to new compliance structure"
  task migrate_compliance_structure: :environment do
    puts "Migrating env_json to new compliance structure..."
    puts ""

    updated_count = 0
    skipped_count = 0
    error_count = 0

    Version.find_each do |version|
      begin
        env_data = JSON.parse(version.env_json.presence || '{}')

        # Check if already migrated to new compliance structure
        existing_schemas = env_data.dig('compliance', '1')
        if existing_schemas.is_a?(Array) && existing_schemas.any?
          # Backfill new fields and clean up deprecated ones
          changed = false
          existing_schemas.each do |schema|
            unless schema.key?('url')
              schema['url'] = 'https://sc-fair.org'
              changed = true
            end
            if schema['name'] == 'CELLxGENE cell metadata schema'
              schema['name'] = 'scFAIR'
              schema['source_schema_name'] = 'CELLxGENE schema'
              schema['description'] = 'scFAIR is using the CELLxGENE cell metadata schema to validate single-cell transcriptomics datasets'
              changed = true
            end
            unless schema.key?('source_schema_name')
              schema['source_schema_name'] ||= 'CELLxGENE schema'
              changed = true
            end
            unless schema.key?('description')
              schema['description'] ||= 'scFAIR is using the CELLxGENE cell metadata schema to validate single-cell transcriptomics datasets'
              changed = true
            end
            if schema.key?('not_validated_icon')
              schema.delete('not_validated_icon')
              changed = true
            end
          end
          if changed
            version.update!(env_json: JSON.generate(env_data))
            puts "  Version ##{version.id}: Updated fields"
            updated_count += 1
          else
            puts "  Version ##{version.id}: Already up to date, skipping"
            skipped_count += 1
          end
          next
        end

        # Determine version from old structures
        cxg_version = env_data.dig('validation', 'single_cell', 'version') ||
                      env_data['cxg_schema_version'] ||
                      '7.1.0'
        source_url = env_data.dig('validation', 'single_cell', 'schema_url') ||
                     "https://github.com/chanzuckerberg/single-cell-curation/blob/main/schema/#{cxg_version}/schema.md"

        # Create new compliance structure
        env_data['compliance'] = {
          '1' => [
            {
              'name' => 'scFAIR',
              'version' => cxg_version,
              'source_schema_name' => 'CELLxGENE schema',
              'description' => 'scFAIR is using the CELLxGENE cell metadata schema to validate single-cell transcriptomics datasets',
              'source_url' => source_url,
              'url' => 'https://sc-fair.org',
              'compliant_icon' => 'scfair_badge_compliant.svg',
              'not_compliant_icon' => 'scfair_badge_noncompliant.svg',
              'if_compliant' => ['allow_public']
            }
          ]
        }

        # Remove old structures
        env_data.delete('validation')
        env_data.delete('cxg_schema_version')

        version.update!(env_json: JSON.generate(env_data))
        puts "  Version ##{version.id}: Migrated to compliance structure (version: #{cxg_version})"
        updated_count += 1

      rescue StandardError => e
        puts "  Version ##{version.id}: ERROR - #{e.message}"
        error_count += 1
      end
    end

    puts ""
    puts "Summary:"
    puts "  Updated: #{updated_count}"
    puts "  Skipped: #{skipped_count}"
    puts "  Errors:  #{error_count}"
    puts "  Total:   #{Version.count}"
  end

  desc "Update compliance config: replace CELLxGENE references with scFAIR"
  task update_compliance_to_scfair: :environment do
    puts "Updating compliance config in all Versions to reference scFAIR..."
    puts ""

    updated_count = 0
    skipped_count = 0
    error_count = 0

    old_source_url = "https://github.com/chanzuckerberg/single-cell-curation/blob/main/schema/7.1.0/schema.md"
    new_source_url = "https://github.com/scFAIR/scFAIR/blob/main/schema/7.1.0/README.md"

    Version.find_each do |version|
      begin
        env_data = JSON.parse(version.env_json.presence || '{}')
        comp = env_data['compliance']
        next unless comp.is_a?(Hash)

        changed = false
        comp.each do |_pt_id, schemas|
          next unless schemas.is_a?(Array)
          schemas.each do |s|
            if s['source_url'] == old_source_url
              s['source_url'] = new_source_url
              changed = true
            end
            if s['source_schema_name'] == 'CELLxGENE schema'
              s['source_schema_name'] = 'scFAIR schema'
              changed = true
            end
            if s['description']&.include?('CELLxGENE')
              s['description'] = 'scFAIR validates single-cell transcriptomics datasets against the scFAIR cell metadata schema'
              changed = true
            end
          end
        end

        if changed
          version.update!(env_json: JSON.generate(env_data))
          puts "  Version ##{version.id}: Updated"
          updated_count += 1
        else
          puts "  Version ##{version.id}: Already up to date, skipping"
          skipped_count += 1
        end

      rescue StandardError => e
        puts "  Version ##{version.id}: ERROR - #{e.message}"
        error_count += 1
      end
    end

    puts ""
    puts "Summary:"
    puts "  Updated: #{updated_count}"
    puts "  Skipped: #{skipped_count}"
    puts "  Errors:  #{error_count}"
    puts "  Total:   #{Version.count}"
  end

end

namespace :std_methods do
  desc "Update integration std_method: allowed_downstream_steps + R script name"
  task update_integration: :environment do
    puts "Updating integration std_method..."

    methods = StdMethod.where(name: 'integration')
    if methods.empty?
      puts "  No integration std_method found, skipping"
      exit 0
    end

    updated_count = 0
    methods.each do |method|
      changed = false

      obj_attrs = Basic.safe_parse_json(method.obj_attrs_json, {})
      unless obj_attrs['allowed_downstream_steps'].present?
        obj_attrs['allowed_downstream_steps'] = ['umap', 'clustering']
        method.obj_attrs_json = JSON.generate(obj_attrs)
        puts "  StdMethod ##{method.id}: added allowed_downstream_steps"
        changed = true
      end

      if method.command_json.present? && method.command_json.include?('integration.R') && !method.command_json.include?('integration.v8.R')
        method.command_json = method.command_json.gsub('integration.R', 'integration.v8.R')
        puts "  StdMethod ##{method.id}: updated program to integration.v8.R"
        changed = true
      end

      if changed
        method.save!
        updated_count += 1
      else
        puts "  StdMethod ##{method.id}: already up to date, skipping"
      end
    end

    puts ""
    puts "Summary: updated #{updated_count} std_method(s)"
  end
end

namespace :compliance_schemas do
  desc "Seed compliance_schemas table from Version env_json compliance config"
  task seed_from_env_json: :environment do
    puts "Seeding ComplianceSchema records from Version env_json..."
    puts ""

    pt_tag_map = ProjectType.pluck(:id, :tag).to_h

    seen = Set.new
    created_count = 0
    skipped_count = 0

    Version.find_each do |version|
      env_data = JSON.parse(version.env_json.presence || '{}') rescue {}
      comp = env_data['compliance']
      next unless comp.is_a?(Hash)

      comp.each do |pt_id_str, schemas|
        next unless schemas.is_a?(Array)

        tag = pt_tag_map[pt_id_str.to_i] || "type_#{pt_id_str}"

        schemas.each do |s|
          key = [s['name'], s['version'], tag].join('|')
          next if seen.include?(key)
          seen << key

          existing = ComplianceSchema.where(name: s['name'], version: s['version'])
                                     .where("project_type_tags LIKE ?", "%#{tag}%")
                                     .first
          if existing
            puts "  Already exists: #{s['name']} v#{s['version']} (#{tag}), skipping"
            skipped_count += 1
            next
          end

          cs = ComplianceSchema.create!(
            name: s['name'],
            version: s['version'],
            source_schema_name: s['source_schema_name'],
            description: s['description'],
            source_url: s['source_url'],
            url: s['url'],
            compliant_icon: s['compliant_icon'],
            not_compliant_icon: s['not_compliant_icon'],
            project_type_tags: tag,
            if_compliant: Array(s['if_compliant']).join(','),
            active: true,
            started_at: Time.current
          )
          puts "  Created: #{cs.name} v#{cs.version} (#{tag}) -> ComplianceSchema##{cs.id}"
          created_count += 1
        end
      end
    end

    puts ""
    puts "Summary:"
    puts "  Created: #{created_count}"
    puts "  Skipped: #{skipped_count}"
    puts "  Total:   #{ComplianceSchema.count}"
  end
end

namespace :projects do
  desc "Set project_type to Single-cell transcriptomics for public projects with > 100 cols"
  task set_single_cell_for_public: :environment do
    single_cell_type_id = 1
    min_cols = 100

    puts "Setting project_type_id=#{single_cell_type_id} (Single-cell transcriptomics)"
    puts "for public projects with more than #{min_cols} cols..."
    puts ""

    projects = Project.where(public: true)
                      .where('nber_cols > ?', min_cols)
                      .where('project_type_id IS NULL OR project_type_id != ?', single_cell_type_id)

    total = projects.count
    puts "Found #{total} project(s) to update."
    puts ""

    updated_count = 0
    error_count = 0

    projects.find_each do |project|
      begin
        old_type = project.project_type_id
        project.update!(project_type_id: single_cell_type_id)
        puts "  Project ##{project.id} (#{project.nber_cols} cols): project_type_id #{old_type.inspect} -> #{single_cell_type_id}"
        updated_count += 1
      rescue StandardError => e
        puts "  Project ##{project.id}: ERROR - #{e.message}"
        error_count += 1
      end
    end

    puts ""
    puts "Summary:"
    puts "  Updated: #{updated_count}"
    puts "  Errors:  #{error_count}"
    puts "  Total candidates: #{total}"
  end

  desc "Backfill missing num_matrix/int_matrix data class on parsing /matrix annotations"
  task fix_parsing_matrix_data_classes: :environment do
    num_matrix_id = DataClass.find_by(name: 'num_matrix')&.id
    int_matrix_id = DataClass.find_by(name: 'int_matrix')&.id
    unless num_matrix_id && int_matrix_id
      puts "DataClass num_matrix (#{num_matrix_id}) or int_matrix (#{int_matrix_id}) not found, aborting."
      next
    end

    parsing_step_ids = Step.where(name: 'parsing').pluck(:id)
    matrix_annots = Annot.where(step_id: parsing_step_ids, name: '/matrix')

    broken = matrix_annots.select { |a|
      dc_ids = (a.data_class_ids || '').split(',').map(&:to_i)
      !dc_ids.include?(num_matrix_id) && !dc_ids.include?(int_matrix_id)
    }

    puts "Found #{broken.size} parsing /matrix annotations missing num_matrix/int_matrix"

    updated = 0
    skipped = 0
    errors = 0

    broken.each do |annot|
      run = Run.find_by(id: annot.run_id)
      unless run&.output_json.present?
        puts "  annot #{annot.id}: no run or output_json, skipped"
        skipped += 1
        next
      end

      h_output = JSON.parse(run.output_json) rescue nil
      om = h_output&.dig('output_matrix')
      unless om
        puts "  annot #{annot.id}: no output_matrix in output_json, skipped"
        skipped += 1
        next
      end

      matrix_type = nil
      om.each_value do |v|
        types = v['types'] || []
        if types.include?('int_matrix')
          matrix_type = int_matrix_id
          break
        elsif types.include?('num_matrix')
          matrix_type = num_matrix_id
          break
        end
      end

      unless matrix_type
        puts "  annot #{annot.id}: output_json has no int_matrix/num_matrix type, skipped"
        skipped += 1
        next
      end

      dc_ids = (annot.data_class_ids || '').split(',').map(&:to_i)
      dc_ids << matrix_type
      new_dc_ids = dc_ids.uniq.sort.join(',')

      begin
        annot.update!(data_class_ids: new_dc_ids)
        puts "  annot #{annot.id}: #{annot.data_class_ids_before_last_save} -> #{new_dc_ids}"
        updated += 1
      rescue StandardError => e
        puts "  annot #{annot.id}: ERROR - #{e.message}"
        errors += 1
      end
    end

    puts ""
    puts "Summary:"
    puts "  Updated: #{updated}"
    puts "  Skipped: #{skipped}"
    puts "  Errors:  #{errors}"
    puts "  Total:   #{broken.size}"
  end

  desc "Fix symlinks that still point to old fus path"
  task fix_fus_symlinks: :environment do
    require 'find'
    require 'pathname'

    old_prefix = ENV.fetch('OLD_PREFIX', '/data/asap2/fus')
    new_prefix = ENV.fetch('NEW_PREFIX', '/data/asap/fus')
    search_root = ENV.fetch('SEARCH_ROOT', ENV.fetch('USER_DATA_DIR', '/data/asap2/projects'))
    link_name = ENV.fetch('LINK_NAME', 'input.loom')
    dry_run = ENV['DRY_RUN'].to_s == '1'

    unless Dir.exist?(search_root)
      puts "SEARCH_ROOT does not exist: #{search_root}"
      exit 1
    end

    normalized_old_prefix = old_prefix.sub(%r{/+\z}, '')
    normalized_new_prefix = new_prefix.sub(%r{/+\z}, '')
    old_prefix_with_sep = "#{normalized_old_prefix}/"

    puts "Search root: #{search_root}"
    puts "Mode: #{dry_run ? 'DRY RUN' : 'APPLY'}"
    puts "Match prefix: #{normalized_old_prefix}"
    puts "Replace with: #{normalized_new_prefix}"
    puts "Link name filter: #{link_name}"
    puts ""

    scanned_symlinks = 0
    matched_symlinks = 0
    updated_symlinks = 0
    skipped_missing_new_target = 0
    errors = 0

    Find.find(search_root) do |path|
      next unless File.symlink?(path)
      next unless File.basename(path) == link_name

      scanned_symlinks += 1
      link_target = File.readlink(path)

      absolute_target = if Pathname.new(link_target).absolute?
        link_target
      else
        File.expand_path(link_target, File.dirname(path))
      end

      next unless absolute_target == normalized_old_prefix || absolute_target.start_with?(old_prefix_with_sep)

      matched_symlinks += 1
      new_absolute_target = absolute_target.sub(normalized_old_prefix, normalized_new_prefix)

      unless File.exist?(new_absolute_target)
        skipped_missing_new_target += 1
        puts "[SKIP] #{path} -> #{new_absolute_target} (new target does not exist)"
        next
      end

      new_link_target = if Pathname.new(link_target).absolute?
        new_absolute_target
      else
        Pathname.new(new_absolute_target).relative_path_from(Pathname.new(File.dirname(path))).to_s
      end

      if dry_run
        puts "[DRY RUN] #{path}: #{link_target} -> #{new_link_target}"
        next
      end

      begin
        File.delete(path)
        File.symlink(new_link_target, path)
        updated_symlinks += 1
        puts "[UPDATED] #{path}: #{link_target} -> #{new_link_target}"
      rescue StandardError => e
        errors += 1
        puts "[ERROR] #{path}: #{e.class} - #{e.message}"
      end
    end

    puts ""
    puts "Summary:"
    puts "  Symlinks scanned:           #{scanned_symlinks}"
    puts "  Symlinks matched old path:  #{matched_symlinks}"
    puts "  Updated:                    #{updated_symlinks}"
    puts "  Skipped missing new target: #{skipped_missing_new_target}"
    puts "  Errors:                     #{errors}"

    exit 1 if errors.positive?
  end
end
