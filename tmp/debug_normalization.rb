project = Project.find(69560)
puts "=== Project #{project.id} ==="
puts "Version: #{project.version_id}"

# Get docker image
asap_docker_image = Basic.get_asap_docker(project.version)
puts "Docker image: #{asap_docker_image ? asap_docker_image.id : 'NONE'}"

# Get normalization step
normalization_step = Step.joins(:docker_image).where(docker_images: { id: asap_docker_image.id }, name: 'normalization').first
if normalization_step.nil?
  puts "ERROR: Normalization step not found!"
  exit
end
puts "Normalization step ID: #{normalization_step.id}"
puts "Normalization step attrs_json: #{normalization_step.attrs_json}"

# Get std_methods
std_methods = StdMethod.where(docker_image_id: asap_docker_image.id, step_id: normalization_step.id, obsolete: false).all
puts "StdMethods count: #{std_methods.count}"
std_methods.each do |m|
  puts "  StdMethod #{m.id}: #{m.name}"
  puts "    attrs_json: #{m.attrs_json}"
end

# Get successful runs
successful_runs = Run.where(project_id: project.id, status_id: 3).all
puts "Successful runs count: #{successful_runs.count}"
successful_runs.each do |r|
  step = Step.find_by(id: r.step_id)
  puts "  Run #{r.id}: step_id=#{r.step_id}, step_name=#{step ? step.name : 'N/A'}"
end

# Get available annotations
run_ids = successful_runs.map(&:id)
available_annots = Annot.where(project_id: project.id).where("run_id IN (?) OR ori_run_id IN (?)", run_ids, run_ids).includes(:run).all
puts "Available annotations count: #{available_annots.count}"

# Get steps hash
h_steps = {}
Step.all.each { |s| h_steps[s.id] = s }
h_steps_by_name = {}
h_steps.each { |id, s| h_steps_by_name[s.name] = s if s.respond_to?(:name) }

# Get data classes
h_data_classes = {}
DataClass.all.each { |dc| h_data_classes[dc.id] = dc; h_data_classes[dc.name] = dc }

# Test each std_method
std_methods.each do |std_method|
  puts "\n=== Testing StdMethod #{std_method.id} (#{std_method.name}) ==="
  
  step_attrs = Basic.safe_parse_json(normalization_step.attrs_json, {})
  method_attrs = Basic.safe_parse_json(std_method.attrs_json, {})
  combined_attrs = step_attrs.deep_merge(method_attrs)
  
  puts "Combined attrs keys: #{combined_attrs.keys.inspect}"
  
  all_params_satisfied = true
  
  combined_attrs.each do |attr_name, attr_config|
    next unless attr_config.is_a?(Hash)
    next unless attr_config['source_steps'].present? && attr_config['valid_types'].present?
    
    puts "\n  Parameter: #{attr_name}"
    puts "    source_steps: #{attr_config['source_steps'].inspect}"
    puts "    valid_types: #{attr_config['valid_types'].inspect}"
    
    source_steps = attr_config['source_steps']
    valid_types = attr_config['valid_types']
    
    source_step_ids = source_steps.map { |ssn| h_steps_by_name[ssn]&.id }.compact
    puts "    source_step_ids: #{source_step_ids.inspect}"
    
    source_steps.each do |ssn|
      step_obj = h_steps_by_name[ssn]
      puts "      Step '#{ssn}': #{step_obj ? "found (id=#{step_obj.id})" : 'NOT FOUND'}"
    end
    
    next if source_step_ids.empty?
    
    # Filter annotations
    source_annots = available_annots.select do |annot|
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
        puts "      Annot #{annot.id}: step_id=#{annot.step_id}, ori_step_id=#{annot.ori_step_id}, run_id=#{annot.run_id}, ori_run_id=#{annot.ori_run_id}, data_class_ids=#{annot.data_class_ids}, data_class_names=#{annot_data_class_names.inspect}"
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
        puts "        valid_types requirement: #{valid_types.inspect}"
      end
      
      matches
    end
    
    puts "    Has valid dataset: #{has_valid_dataset}"
    
    unless has_valid_dataset
      all_params_satisfied = false
      puts "    FAILED: Parameter #{attr_name} does not have valid dataset"
    end
  end
  
  puts "\n  Result for StdMethod #{std_method.id}: #{all_params_satisfied ? 'PASSED' : 'FAILED'}"
end



