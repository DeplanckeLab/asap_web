class SetMultipleRunsFalseForV8Steps < ActiveRecord::Migration[8.0]
  def up
    return unless table_exists?(:steps)
    return unless table_exists?(:docker_images)
    
    # Find the docker image for fabdavid/asap_run:v8
    docker_image = DockerImage.find_by(name: 'fabdavid/asap_run', tag: 'v8')
    
    if docker_image
      # Update steps with rank < 17 and rank > 5 for this docker image
      Step.where(docker_image_id: docker_image.id)
          .where('rank < ?', 17).where('rank > ?', 5)
          .update_all(multiple_runs: false)
    else
      puts "Warning: Docker image 'fabdavid/asap_run:v8' not found. Skipping migration."
    end
  end

  def down
    return unless table_exists?(:steps)
    return unless table_exists?(:docker_images)
    
    # Find the docker image for fabdavid/asap_run:v8
    docker_image = DockerImage.find_by(name: 'fabdavid/asap_run', tag: 'v8')
    
    if docker_image
      # Revert: set multiple_runs back to true (default value)
      Step.where(docker_image_id: docker_image.id)
          .where('rank < ?', 17).where('rank > ?', 5)
          .update_all(multiple_runs: true)
    end
  end
end



