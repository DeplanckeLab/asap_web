project = Project.find(69560)
puts "=== Debugging HVG step unlock for project #{project.id} ===\n"

# Get docker image
asap_docker_image = Basic.get_asap_docker(project.version)
puts "Docker image ID: #{asap_docker_image.id}\n\n"

# Get HVG step (gene_filtering)
hvg_step = Step.where(docker_image_id: asap_docker_image.id, name: 'gene_filtering').first
if hvg_step.nil?
  puts "ERROR: HVG step (gene_filtering) not found!"
  exit
end

puts "HVG step ID: #{hvg_step.id}"
puts "HVG step name: #{hvg_step.name}\n\n"

# Get std_methods for HVG
std_methods = StdMethod.where(docker_image_id: asap_docker_image.id, step_id: hvg_step.id, obsolete: false).all
puts "StdMethods count: #{std_methods.count}\n\n"

# Get all annotations
all_annots = Annot.where(project_id: project.id).includes(:run).all
puts "Total annotations in project: #{all_annots.count}\n\n"

# Get steps hash
h_steps = {}
Step.all.each { |s| h_steps[s.id] = s }

# Get steps by name from project's docker_image_id
h_steps_by_name = {}
Step.where(docker_image_id: asap_docker_image.id).each { |s| h_steps_by_name[s.name] = s if s.respond_to?(:name) }

# Get data classes
h_data_classes = {}
DataClass.all.each { |dc| h_data_classes[dc.id] = dc; h_data_classes[dc.name] = dc }

# Test each std_method
std_methods.each do |std_method|
  puts "=== Testing StdMethod #{std_method.id} (#{std_method.name}) ===\n"
  
  # Get combined attrs using Basic.get_std_method_attrs
  begin
    h_res = Basic.get_std_method_attrs(std_method, hvg_step)
    combined_attrs = h_res[:h_attrs] || {}
    puts "Combined attrs keys: #{combined_attrs.keys.inspect}\n"
  rescue => e
    puts "Error calling get_std_method_attrs: #{e.message}\n"
    # Fallback
    step_attrs = Basic.safe_parse_json(hvg_step.attrs_json, {})
    method_attrs = Basic.safe_parse_json(std_method.attrs_json, {})
    method_obj_attrs = Basic.safe_parse_json(std_method.obj_attrs_json, {})
    combined_attrs = step_attrs.deep_merge(method_attrs).deep_merge(method_obj_attrs)
    puts "Using fallback - Combined attrs keys: #{combined_attrs.keys.inspect}\n"
  end
  
  all_params_satisfied = true
  
  combined_attrs.each do |attr_name, attr_config|
    next unless attr_config.is_a?(Hash)
    next unless attr_config['source_steps'].present? && attr_config['valid_types'].present?
    
    puts "\n  Parameter: #{attr_name}"
    puts "    source_steps: #{attr_config['source_steps'].inspect}"
    puts "    valid_types: #{attr_config['valid_types'].inspect}"
    
    source_steps = attr_config['source_steps']
    valid_types = attr_config['valid_types']
    
    # Get source step IDs from project's docker_image_id
    source_step_ids = source_steps.map { |ssn| h_steps_by_name[ssn]&.id }.compact
    puts "    source_step_ids: #{source_step_ids.inspect}"
    
    source_steps.each do |ssn|
      step_obj = h_steps_by_name[ssn]
      puts "      Step '#{ssn}': #{step_obj ? "found (id=#{step_obj.id})" : 'NOT FOUND'}"
    end
    
    next if source_step_ids.empty?
    
    # Filter annotations
    source_annots = all_annots.select do |annot|
      if annot.step_id && source_step_ids.include?(annot.step_id)
        true
      elsif annot.ori_step_id && source_step_ids.include?(annot.ori_step_id)
        true
      else
        annot_run = if annot.run_id && annot.run
                      annot.run
                    elsif annot.ori_run_id
                      Run.find_by(id: annot.ori_run_id)
                    else
                      nil
                    end
        annot_run && source_step_ids.include?(annot_run.step_id)
      end
    end
    
    puts "    Source annotations count: #{source_annots.count}"
    
    if source_annots.count > 0
      puts "    First 5 annotations:"
      source_annots.first(5).each do |annot|
        annot_data_class_names = annot.data_class_ids.present? ? annot.data_class_ids.split(',').map { |dc_id| h_data_classes[dc_id.to_i]&.name }.compact : []
        puts "      Annot #{annot.id}: step_id=#{annot.step_id}, ori_step_id=#{annot.ori_step_id}, run_id=#{annot.run_id}, ori_run_id=#{annot.ori_run_id}"
        puts "        data_class_ids=#{annot.data_class_ids}, data_class_names=#{annot_data_class_names.inspect}"
      end
    end
    
    # Check if any annotation matches valid_types
    has_valid_dataset = source_annots.any? do |annot|
      next false unless annot.data_class_ids.present?
      
      annot_data_class_names = annot.data_class_ids.split(',').map do |dc_id|
        h_data_classes[dc_id.to_i]&.name
      end.compact
      
      matches = valid_types.all? do |or_group|
        or_group.any? { |valid_type| annot_data_class_names.include?(valid_type) }
      end
      
      if matches
        puts "      MATCH FOUND: Annot #{annot.id} matches valid_types"
        puts "        data_class_names: #{annot_data_class_names.inspect}"
      end
      
      matches
    end
    
    puts "    Has valid dataset: #{has_valid_dataset}"
    
    unless has_valid_dataset
      all_params_satisfied = false
      puts "    FAILED: Parameter #{attr_name} does not have valid dataset"
    end
  end
  
  puts "\n  Result for StdMethod #{std_method.id}: #{all_params_satisfied ? 'PASSED' : 'FAILED'}\n"
  puts "  This std_method #{all_params_satisfied ? 'CAN' : 'CANNOT'} be used\n\n"
end

# Summary
puts "=== SUMMARY ==="
puts "HVG step should be unlocked if at least one std_method passes all requirements."
puts "Check the results above to see which std_methods passed."

