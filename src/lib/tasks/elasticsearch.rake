namespace :elasticsearch do
  desc "Index all projects in Elasticsearch"
  task index_projects: :environment do
    puts "Indexing projects in Elasticsearch..."
    
    # Create index if it doesn't exist
    unless Project.__elasticsearch__.index_exists?
      Project.__elasticsearch__.create_index!(force: true)
      puts "Created Elasticsearch index for projects"
    end
    
    # Index all projects
    Project.find_each do |project|
      begin
        # Skip indexing if project has missing required fields
        next unless project.respond_to?(:name) && project.respond_to?(:key)
        
        project.__elasticsearch__.index_document
        print "."
      rescue => e
        puts "\nError indexing project #{project.id}: #{e.message}"
        next
      end
    end
    
    puts "\nIndexing complete!"
    puts "Total projects indexed: #{Project.count}"
  end
  
  desc "Reindex all projects in Elasticsearch"
  task reindex_projects: :environment do
    puts "Reindexing projects in Elasticsearch..."
    
    # Delete existing index
    if Project.__elasticsearch__.index_exists?
      Project.__elasticsearch__.delete_index!
      puts "Deleted existing index"
    end
    
    # Create new index
    Project.__elasticsearch__.create_index!(force: true)
    puts "Created new index"
    
    # Index all projects
    Project.find_each do |project|
      begin
        # Skip indexing if project has missing required fields
        next unless project.respond_to?(:name) && project.respond_to?(:key)
        
        project.__elasticsearch__.index_document
        print "."
      rescue => e
        puts "\nError indexing project #{project.id}: #{e.message}"
        next
      end
    end
    
    puts "\nReindexing complete!"
    puts "Total projects indexed: #{Project.count}"
  end
  
  desc "Check Elasticsearch status"
  task status: :environment do
    begin
      client = Elasticsearch::Model.client
      info = client.info
      puts "Elasticsearch is running:"
      puts "  Version: #{info['version']['number']}"
      puts "  Cluster: #{info['cluster_name']}"
      puts "  Node: #{info['name']}"
      
      if Project.__elasticsearch__.index_exists?
        count = Project.__elasticsearch__.search(size: 0).response['hits']['total']['value']
        puts "  Projects indexed: #{count}"
      else
        puts "  Projects index: Not found"
      end
    rescue => e
      puts "Error connecting to Elasticsearch: #{e.message}"
    end
  end
end
