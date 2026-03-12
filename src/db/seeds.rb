# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).
#
# Example:
#
#   ["Action", "Comedy", "Drama", "Horror"].each do |genre_name|
#     MovieGenre.find_or_create_by!(name: genre_name)
#   end

puts "Seeding project type labels..."

project_type_labels = {
  "Single-cell transcriptomics" => { row_label: "genes", col_label: "cells" },
  "Bulk transcriptomics" => { row_label: "genes", col_label: "samples" }
}

project_type_labels.each do |name, labels|
  project_type = ProjectType.find_by(name: name)

  unless project_type
    puts "ProjectType not found: #{name}"
    next
  end

  project_type.assign_attributes(labels)

  if project_type.changed?
    project_type.save!
    puts "Updated #{name}: row_label=#{project_type.row_label}, col_label=#{project_type.col_label}"
  else
    puts "No change for #{name}"
  end
end
