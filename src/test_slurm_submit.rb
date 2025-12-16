# Test SLURM job submission using existing Run
# Find a waiting run (status_id: 1) or use the most recent run
run = Run.where(status_id: 1).order(:created_at).first || Run.order(:created_at).last

unless run
  puts "ERROR: No runs found in database"
  exit
end

puts "Testing SLURM job submission for Run##{run.id}"
puts "  Project: #{run.project&.key || 'N/A'}"
puts "  User ID: #{run.project&.user_id || 'N/A'}"
puts "  Current status_id: #{run.status_id}"
puts "  Cores: #{run.nber_cores || 1}"
puts "  Memory: #{run.pred_max_ram || run.max_ram || 1024}MB"
puts "  Time limit: #{run.pred_process_duration || 3600}s"

slurm_service = SlurmService.new
command = 'echo "Test job from Rails - $(date)" && sleep 5 && echo "Job completed"'

begin
  # Use the run's actual resource requirements, but ensure minimums
  cores = [run.nber_cores || 1, 1].max
  memory_mb = [(run.pred_max_ram || run.max_ram || 512).to_i, 512].max
  time_limit = run.pred_process_duration || 3600
  
  puts "  Submitting with: #{cores} cores, #{memory_mb}MB memory, #{time_limit}s time"
  
  slurm_job_id = slurm_service.submit_job(
    run, 
    command, 
    cores: cores,
    memory_mb: memory_mb,
    time_limit: time_limit
  )
  puts "SUCCESS: Job submitted with SLURM Job ID: #{slurm_job_id}"
  
  sleep 2
  status = slurm_service.get_job_status(slurm_job_id)
  puts "Job status: #{status}"
  
  sleep 5
  status2 = slurm_service.get_job_status(slurm_job_id)
  puts "Job status after 5s: #{status2}"
rescue => e
  puts "ERROR: #{e.message}"
  puts e.backtrace.first(5).join("\n")
end

