project = Project.find(69560)
puts "=== Checking annotations for project #{project.id} ===\n"

# Get docker image
asap_docker_image = Basic.get_asap_docker(project.version)

# Get steps
h_steps = {}
Step.all.each { |s| h_steps[s.id] = s }
h_steps_by_name = {}
h_steps.each { |id, s| h_steps_by_name[s.name] = s if s.respond_to?(:name) }

# Get data classes
h_data_classes = {}
DataClass.all.each { |dc| h_data_classes[dc.id] = dc; h_data_classes[dc.name] = dc }

# Get all annotations
all_annots = Annot.where(project_id: project.id).includes(:run).all
puts "Total annotations: #{all_annots.count}\n\n"

# Check annotations from parsing, cell_filtering, gene_filtering, normalization
source_step_names = ['parsing', 'cell_filtering', 'gene_filtering', 'normalization']
source_step_ids = source_step_names.map { |n| h_steps_by_name[n]&.id }.compact

puts "Source step IDs: #{source_step_ids.inspect}\n"
source_step_names.each do |name|
  step = h_steps_by_name[name]
  puts "  #{name}: #{step ? "id=#{step.id}" : "NOT FOUND"}"
end

puts "\n=== Annotations from source steps ===\n"
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

puts "Found #{source_annots.count} annotations from source steps\n\n"

# Check valid_types: [["dataset"], ["num_matrix", "int_matrix"]]
valid_types = [["dataset"], ["num_matrix", "int_matrix"]]

puts "=== Checking annotations matching valid_types: #{valid_types.inspect} ===\n"
matching_annots = source_annots.select do |annot|
  next false unless annot.data_class_ids.present?
  
  annot_data_class_names = annot.data_class_ids.split(',').map do |dc_id|
    h_data_classes[dc_id.to_i]&.name
  end.compact
  
  matches = valid_types.all? do |or_group|
    or_group.any? { |valid_type| annot_data_class_names.include?(valid_type) }
  end
  
  if matches
    puts "MATCH: Annot #{annot.id}"
    puts "  step_id: #{annot.step_id}, ori_step_id: #{annot.ori_step_id}"
    puts "  run_id: #{annot.run_id}, ori_run_id: #{annot.ori_run_id}"
    puts "  data_class_ids: #{annot.data_class_ids}"
    puts "  data_class_names: #{annot_data_class_names.inspect}"
    puts ""
  end
  
  matches
end

puts "Total matching annotations: #{matching_annots.count}\n"


