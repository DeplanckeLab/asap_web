namespace :exp_entries do
  desc "Update exp_entry DOIs from PubMed for entries that have PMID but no DOI"
  task update_dois: :environment do
    puts "Updating exp_entry DOIs from PubMed..."
    count = Fetch.update_exp_entry_dois
    puts "Updated #{count} exp_entries with DOIs"
  end

  desc "Update exp_entry DOIs for a specific project"
  task :update_dois_for_project, [:project_id] => :environment do |t, args|
    project = Project.find(args[:project_id])
    puts "Updating exp_entry DOIs for project #{project.id}: #{project.name}..."
    count = Fetch.update_exp_entry_dois(project)
    puts "Updated #{count} exp_entries with DOIs"
  end

  desc "Propagate project DOI to its exp_entries that don't have their own DOI"
  task :propagate_project_doi, [:project_id] => :environment do |t, args|
    project = Project.find(args[:project_id])
    puts "Propagating DOI from project #{project.id}: #{project.name}..."
    puts "Project DOI: #{project.doi}"
    count = Fetch.propagate_project_doi(project)
    puts "Updated #{count} exp_entries with project DOI"
  end

  desc "Propagate DOIs for all projects that have a DOI"
  task propagate_all_project_dois: :environment do
    puts "Propagating DOIs from all projects..."
    total = 0
    Project.where.not(doi: [nil, '']).find_each do |project|
      count = Fetch.propagate_project_doi(project)
      if count > 0
        puts "Project #{project.id} (#{project.key}): #{count} exp_entries updated"
        total += count
      end
    end
    puts "Total: #{total} exp_entries updated"
  end

  desc "Refresh ArrayExpress metadata for exp_entries"
  task :refresh_array_express, [:identifier] => :environment do |t, args|
    if args[:identifier]
      puts "Refreshing ArrayExpress metadata for #{args[:identifier]}..."
      exp_entry = Fetch.fetch_array_express(args[:identifier])
      if exp_entry
        puts "Updated: #{exp_entry.identifier}"
        puts "  Title: #{exp_entry.title}"
        puts "  PMID: #{exp_entry.pmid}"
        puts "  DOI: #{exp_entry.doi}"
      end
    else
      puts "Refreshing all ArrayExpress entries..."
      ExpEntry.where(identifier_type_id: 6).find_each do |exp_entry|
        print "Refreshing #{exp_entry.identifier}... "
        updated = Fetch.fetch_array_express(exp_entry.identifier)
        puts updated ? "Done (DOI: #{updated.doi || 'none'})" : "Failed"
        sleep 0.5 # Rate limiting
      end
    end
  end
end

