# Test SLURM job submission from Rails
user = User.first
project = user.projects.first || user.projects.create(key: 'test_slurm', name: 'Test SLURM Project')
step = project.steps.first || project.steps.create(name: 'test_step', status_id: 1)
run = project.runs.create(step_id: step.id, status_id: 1, nber_cores: 1, pred_max_ram: 1024, pred_process_duration: 60)

# Test job submission
slurm_service = SlurmService.new
command = 'echo "Test job from Rails - $(date)" && sleep 5 && echo "Job completed"'
puts "Submitting test job for Run##{run.id}..."
begin
  slurm_job_id = slurm_service.submit_job(run, command, cores: 1, memory_mb: 512, time_limit: 60)
  puts "SUCCESS: Job submitted with SLURM Job ID: #{slurm_job_id}"
  puts "Checking job status..."
  sleep 2
  status = slurm_service.get_job_status(slurm_job_id)
  puts "Job status: #{status}"
  puts "Checking queue..."
  sleep 3
  status2 = slurm_service.get_job_status(slurm_job_id)
  puts "Job status after 3s: #{status2}"
rescue => e
  puts "ERROR: #{e.message}"
  puts e.backtrace.first(5).join("\n")
end

