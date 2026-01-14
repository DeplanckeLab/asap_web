# Update project_types with row_label and col_label values
# This file can be run with: rails runner db/update_project_types_labels.rb
# Or loaded in Rails console: load 'db/update_project_types_labels.rb'

puts "Updating project_types with row_label and col_label values..."

# Update Single-cell transcriptomics
single_cell = ProjectType.find_by(name: 'Single-cell transcriptomics')
if single_cell
  single_cell.update_columns(
    row_label: 'genes',
    col_label: 'cells',
    updated_at: Time.current
  )
  puts "Updated: #{single_cell.name} (id: #{single_cell.id}) -> row_label: genes, col_label: cells"
else
  puts "Warning: 'Single-cell transcriptomics' project type not found"
end

# Update Bulk transcriptomics
bulk = ProjectType.find_by(name: 'Bulk transcriptomics')
if bulk
  bulk.update_columns(
    row_label: 'genes',
    col_label: 'samples',
    updated_at: Time.current
  )
  puts "Updated: #{bulk.name} (id: #{bulk.id}) -> row_label: genes, col_label: samples"
else
  puts "Warning: 'Bulk transcriptomics' project type not found"
end

# Add more project types here as needed:
# Example:
# other_type = ProjectType.find_by(name: 'Other Type Name')
# if other_type
#   other_type.update_columns(row_label: 'genes', col_label: 'samples', updated_at: Time.current)
#   puts "Updated: #{other_type.name}"
# end

puts "\nAll project types:"
ProjectType.order(:id).each do |pt|
  puts "  ID: #{pt.id}, Name: #{pt.name}, Tag: #{pt.tag || 'N/A'}, Row Label: #{pt.row_label || 'N/A'}, Col Label: #{pt.col_label || 'N/A'}"
end

puts "\nDone!"

