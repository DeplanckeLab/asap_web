namespace :runs do

  desc 'rescue runs'
  task :rescue_runs, [] => :environment do |_t, args|

    #get the runs that are in a running status

    # for each of them check if there is a slurm job running
    # otherwise we check if the run finished (if output.json exists in the run's path, running Basic.finish_run should move the run to success or failed status) 
   
    
  end
end
