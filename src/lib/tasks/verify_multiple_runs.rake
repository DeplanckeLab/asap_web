namespace :db do
  desc 'Verify multiple_runs values for v8 steps with rank > 5 and < 17'
  task verify_multiple_runs_v8: :environment do
    puts "Verifying multiple_runs values for fabdavid/asap_run:v8 steps..."
    
    # Find the docker image
    docker_image = DockerImage.find_by(name: 'fabdavid/asap_run', tag: 'v8')
    
    unless docker_image
      puts "ERROR: Docker image 'fabdavid/asap_run:v8' not found!"
      exit 1
    end
    
    puts "Found docker image: ID=#{docker_image.id}, name=#{docker_image.name}, tag=#{docker_image.tag}"
    
    # Query steps with rank > 5 and < 17
    steps = Step.where(docker_image_id: docker_image.id)
                .where('rank > ?', 5)
                .where('rank < ?', 17)
                .order(:rank)
    
    puts "\nFound #{steps.count} steps with rank > 5 and < 17:"
    puts "-" * 80
    
    all_true = true
    steps.each do |step|
      status = step.multiple_runs ? "true" : "FALSE"
      all_true = false unless step.multiple_runs
      puts "Step ID: #{step.id}, Name: #{step.name}, Rank: #{step.rank}, multiple_runs: #{status}"
    end
    
    puts "-" * 80
    
    if all_true
      puts "\nSUCCESS: All steps have multiple_runs = true"
    else
      puts "\nWARNING: Some steps have multiple_runs = false!"
      false_steps = steps.select { |s| !s.multiple_runs }
      puts "Steps with multiple_runs = false:"
      false_steps.each do |step|
        puts "  - Step ID: #{step.id}, Name: #{step.name}, Rank: #{step.rank}"
      end
    end
    
    puts "\nVerification complete."
  end
end

