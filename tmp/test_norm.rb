project = Project.find(69560)
puts "Project: #{project.id}, Version: #{project.version_id}"

asap_docker_image = Basic.get_asap_docker(project.version)
puts "Docker image: #{asap_docker_image.id}"

normalization_step = Step.where(docker_image_id: asap_docker_image.id, name: 'normalization').first
puts "Normalization step: #{normalization_step.id}"

std_methods = StdMethod.where(docker_image_id: asap_docker_image.id, step_id: normalization_step.id, obsolete: false).all
puts "StdMethods: #{std_methods.count}"

std_methods.each do |m|
  puts "\nMethod #{m.id} (#{m.name}):"
  puts "  attrs_json: #{m.attrs_json}"
  puts "  obj_attrs_json: #{m.obj_attrs_json}"
  
  # Check if Basic.get_std_method_attrs exists and use it
  begin
    h_res = Basic.get_std_method_attrs(m, normalization_step)
    h_attrs = h_res[:h_attrs] if h_res.is_a?(Hash)
    if h_attrs
      puts "  Combined attrs from get_std_method_attrs:"
      h_attrs.each do |key, val|
        if val.is_a?(Hash) && (val['source_steps'] || val['valid_types'])
          puts "    #{key}: source_steps=#{val['source_steps']}, valid_types=#{val['valid_types']}"
        end
      end
    end
  rescue => e
    puts "  Error calling get_std_method_attrs: #{e.message}"
  end
end



