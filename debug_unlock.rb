project = Project.find(69560)
puts "=== Debugging unlock logic for project #{project.id} ===\n"

# Get docker image
asap_docker_image = Basic.get_asap_docker(project.version)
puts "Docker image ID: #{asap_docker_image.id}\n\n"

# Get steps hash
h_steps = {}
Step.all.each { |s| h_steps[s.id] = s }

# Get all annotations
all_annots = Annot.where(project_id: project.id).includes(:run).all
puts "Total annotations in project: #{all_annots.count}\n\n"

# Check gene_filtering
gene_filtering_step = Step.where(docker_image_id: asap_docker_image.id, name: 'gene_filtering').first
if gene_filtering_step
  puts "=== GENE_FILTERING STEP (#{gene_filtering_step.id}) ===\n"
  std_methods = StdMethod.where(docker_image_id: asap_docker_image.id, step_id: gene_filtering_step.id, obsolete: false).all
  puts "StdMethods: #{std_methods.count}\n"
  
  if std_methods.empty?
    puts "NO STD_METHODS - Should be unlocked: YES\n\n"
  else
    std_methods.each do |m|
      puts "\nStdMethod #{m.id} (#{m.name}):"
      puts "  attrs_json: #{m.attrs_json}"
      puts "  obj_attrs_json: #{m.obj_attrs_json}"
      
      # Try to get combined attrs
      begin
        h_res = Basic.get_std_method_attrs(m, gene_filtering_step)
        combined_attrs = h_res[:h_attrs] || {}
        puts "  Combined attrs keys: #{combined_attrs.keys.inspect}"
        
        # Check for input requirements
        has_requirements = false
        combined_attrs.each do |key, val|
          if val.is_a?(Hash) && val['source_steps'].present? && val['valid_types'].present?
            has_requirements = true
            puts "    REQUIRED INPUT: #{key}"
            puts "      source_steps: #{val['source_steps']}"
            puts "      valid_types: #{val['valid_types']}"
          end
        end
        
        if !has_requirements
          puts "  NO INPUT REQUIREMENTS - Should pass: YES"
        end
      rescue => e
        puts "  Error getting attrs: #{e.message}"
      end
    end
  end
end

puts "\n\n"

# Check normalization
normalization_step = Step.where(docker_image_id: asap_docker_image.id, name: 'normalization').first
if normalization_step
  puts "=== NORMALIZATION STEP (#{normalization_step.id}) ===\n"
  std_methods = StdMethod.where(docker_image_id: asap_docker_image.id, step_id: normalization_step.id, obsolete: false).all
  puts "StdMethods: #{std_methods.count}\n"
  
  if std_methods.empty?
    puts "NO STD_METHODS - Should be unlocked: YES\n\n"
  else
    std_methods.each do |m|
      puts "\nStdMethod #{m.id} (#{m.name}):"
      puts "  attrs_json: #{m.attrs_json}"
      puts "  obj_attrs_json: #{m.obj_attrs_json}"
      
      # Try to get combined attrs
      begin
        h_res = Basic.get_std_method_attrs(m, normalization_step)
        combined_attrs = h_res[:h_attrs] || {}
        puts "  Combined attrs keys: #{combined_attrs.keys.inspect}"
        
        # Check for input requirements
        has_requirements = false
        combined_attrs.each do |key, val|
          if val.is_a?(Hash) && val['source_steps'].present? && val['valid_types'].present?
            has_requirements = true
            puts "    REQUIRED INPUT: #{key}"
            puts "      source_steps: #{val['source_steps']}"
            puts "      valid_types: #{val['valid_types']}"
          end
        end
        
        if !has_requirements
          puts "  NO INPUT REQUIREMENTS - Should pass: YES"
        end
      rescue => e
        puts "  Error getting attrs: #{e.message}"
      end
    end
  end
end


