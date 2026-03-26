namespace :runs do

  desc 'rescue runs'
  task :rescue_runs, [] => :environment do |_t, args|

    #get the runs that are in a running status

    runs = Run.where(status_id: 2).where.not(slurm_job_id: nil)
    # for each of them check if there is a slurm job running
    # otherwise we check if the run finished (if output.json exists in the run's path, running Basic.finish_run should move the run to success or failed status) 
    runs.each do |run|
      slurm_job_id = run.slurm_job_id
      if slurm_job_id.nil?
        puts "Run #{run.id} has no slurm job id"
      else
        slurm_service = SlurmService.new(logger: Rails.logger)
        status = slurm_service.get_job_status(slurm_job_id, run)
        if status.nil?
          puts "Run #{run.id} has no slurm job id"
        else
          puts "Run #{run.id} has slurm job id #{slurm_job_id} and status #{status}"
          project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + run.project.user_id.to_s + run.project.key
          step_dir = project_dir + run.step.name
          output_dir = (run.step.multiple_runs == true) ? (step_dir + run.id.to_s) : step_dir
          output_json_path = output_dir + 'output.json'
          if File.exist?(output_json_path)
            puts "Run #{run.id} has output.json"
            Basic.finish_run(Rails.logger, run, {})
          else
            puts "Run #{run.id} has no output.json"
          end
        end  
      end
    end
    
  end
end
