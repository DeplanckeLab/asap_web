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
end

