# SLURM Command Reference

Quick reference for checking SLURM job status and managing jobs.

## Quick Status Check

Use the provided script:
```bash
cd /srv/asap2_test
./slurm/check_status.sh
```

## Individual Commands

### Check Cluster Status
```bash
# View cluster nodes and partitions
docker exec slurmctld sinfo

# More detailed cluster info
docker exec slurmctld sinfo -l
```

### Check Job Queue
```bash
# View all jobs in queue
docker exec slurmctld squeue

# View jobs for specific user (if configured)
docker exec slurmctld squeue -u <username>

# View jobs in specific partition
docker exec slurmctld squeue -p debug

# Long format with more details
docker exec slurmctld squeue -l
```

### Check Job Details
```bash
# View details of a specific job
docker exec slurmctld scontrol show job <job_id>

# View details of all jobs
docker exec slurmctld scontrol show jobs

# View node details
docker exec slurmctld scontrol show node slurmd
```

### Check Job History/Accounting
```bash
# View recent job history
docker exec slurmctld sacct

# View jobs from last hour
docker exec slurmctld sacct -S $(date -d '1 hour ago' +%Y-%m-%dT%H:%M:%S)

# View jobs from today
docker exec slurmctld sacct -S today

# Detailed format with resource usage
docker exec slurmctld sacct --format=JobID,JobName,State,ExitCode,Elapsed,MaxRSS,AllocCPUS,ReqMem

# View specific job
docker exec slurmctld sacct -j <job_id> -l
```

### Cancel Jobs
```bash
# Cancel a specific job
docker exec slurmctld scancel <job_id>

# Cancel all jobs for a user
docker exec slurmctld scancel -u <username>

# Cancel all pending jobs
docker exec slurmctld scancel -t PENDING
```

### View Job Output
Job output files are written to the project directories:
```bash
# Find output files for a specific run
find /data/asap2_test -name "slurm_*.out" -mtime -1

# View output of a specific job
cat /data/asap2_test/src/app/.../slurm_<run_id>.out

# View error output
cat /data/asap2_test/src/app/.../slurm_<run_id>.err
```

## Common Job States

- **PENDING (PD)**: Job is waiting for resources
- **RUNNING (R)**: Job is currently executing
- **COMPLETED (CD)**: Job finished successfully
- **FAILED (F)**: Job failed
- **CANCELLED (CA)**: Job was cancelled
- **TIMEOUT (TO)**: Job exceeded time limit

## Troubleshooting

### Check SLURM Service Status
```bash
# Check if SLURM services are running
docker-compose ps slurmctld slurmd slurmdbd

# View SLURM controller logs
docker-compose logs slurmctld

# View compute node logs
docker-compose logs slurmd

# View database daemon logs
docker-compose logs slurmdbd
```

### Restart SLURM Services
```bash
# Restart all SLURM services
docker-compose restart slurmctld slurmd slurmdbd

# Restart just the controller
docker-compose restart slurmctld

# Restart just the compute node
docker-compose restart slurmd
```

### Check if Node is Registered
```bash
# Should show slurmd node as "idle" or "allocated"
docker exec slurmctld sinfo

# If node shows as "down", check logs
docker-compose logs slurmd
```

## Integration with Rails Application

The Rails application automatically:
- Submits jobs via `SlurmService.submit_job`
- Monitors jobs via `SlurmJobMonitorJob`
- Updates run status when jobs complete

You can also check job status programmatically in Rails console:
```ruby
# Find a run
run = Run.find(<run_id>)

# Check SLURM job status
slurm_service = SlurmService.new
status = slurm_service.get_job_status(run.slurm_job_id)
puts "Status: #{status}"

# Get job info
info = slurm_service.get_job_info(run.slurm_job_id)
puts info.inspect
```

