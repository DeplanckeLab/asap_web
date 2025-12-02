# SLURM-Based Run Scheduler

This document describes the new SLURM-based scheduling system that replaces the custom rake-based scheduler.

## Overview

The new system uses SLURM (Simple Linux Utility for Resource Management) to manage job execution instead of directly spawning processes. This provides better resource management, job queuing, and monitoring capabilities.

## Architecture

### Components

1. **SlurmService** (`app/services/slurm_service.rb`)
   - Handles SLURM job submission via `sbatch`
   - Monitors job status using `squeue` and `sacct`
   - Provides job cancellation and information retrieval

2. **RunExecutionJob** (`app/jobs/run_execution_job.rb`)
   - ActiveJob that submits runs to SLURM
   - Builds commands and creates SLURM batch scripts
   - Updates run status and triggers monitoring

3. **SlurmJobMonitorJob** (`app/jobs/slurm_job_monitor_job.rb`)
   - Monitors SLURM job status
   - Handles job completion and failure
   - Calls `finish_run` when jobs complete successfully

4. **Rake Tasks** (`lib/tasks/slurm_scheduler.rake`)
   - `slurm:process_waiting_runs` - Submits waiting runs to SLURM
   - `slurm:monitor_jobs` - Checks status of running SLURM jobs
   - `slurm:start_scheduler` - Continuous scheduler loop (runs every 30 seconds)

## Database Changes

A new migration adds `slurm_job_id` to the `runs` table:
- `slurm_job_id` (integer, nullable) - Stores the SLURM job ID for tracking

## Usage

### Starting the Scheduler

You can run the scheduler in several ways:

1. **One-time processing:**
   ```bash
   rails slurm:process_waiting_runs
   rails slurm:monitor_jobs
   ```

2. **Continuous scheduler (recommended):**
   ```bash
   rails slurm:start_scheduler
   ```

3. **Using a process manager (systemd, supervisor, etc.):**
   Create a service that runs `rails slurm:start_scheduler` in the background.

### Automatic Execution

When `Basic.exec_run` is called with `async: true` (the default), it automatically:
1. Queues a `RunExecutionJob` via ActiveJob
2. The job submits the run to SLURM
3. A `SlurmJobMonitorJob` is scheduled to check status after 30 seconds
4. The monitor job continues checking until completion or failure

### Manual Execution

For synchronous execution (when `async: false`), the old direct spawn method is still used via `exec_run_sync`.

## SLURM Configuration

The system uses the following SLURM directives:
- `--job-name`: Set to `asap_run_{run_id}`
- `--ntasks=1`: Single task per job
- `--cpus-per-task`: From `run.nber_cores` (default: 1)
- `--mem`: From `run.pred_max_ram` or `run.max_ram` (default: 4096M)
- `--time`: From `run.pred_process_duration` (default: 3600 seconds)

## Resource Management

### Resource Requirements

The system handles all four resource parameters:

1. **Predicted Max RAM** (`run.pred_max_ram`)
   - Primary source for memory allocation
   - Falls back to `run.max_ram` if prediction not available
   - Used in `--mem` SLURM directive

2. **Available RAM**
   - SLURM automatically checks cluster availability
   - Optional pre-check via `check_resource_availability` method
   - Jobs queue automatically if insufficient RAM available

3. **Available CPU** (`run.nber_cores`)
   - Uses `run.nber_cores` for CPU count
   - SLURM validates availability when scheduling
   - Jobs queue if requested CPUs not available

4. **Predicted Execution Time** (`run.pred_process_duration`)
   - Used to set `--time` limit in seconds
   - Prevents jobs from running indefinitely
   - SLURM kills jobs exceeding time limit

### Resource Checking

The `SlurmService` includes optional resource availability checking:

```ruby
slurm_service.check_resource_availability(
  cores: 4,
  memory_mb: 8192,
  time_limit: 7200
)
```

This checks if any SLURM partition has sufficient resources before submission. If resources aren't available, the job will still be submitted but will queue until resources become available (SLURM's default behavior).

### Resource Logging

All resource requirements are logged when submitting jobs:
- CPU count and source (nber_cores)
- Memory (predicted vs actual)
- Time limit (predicted duration)

## Job Scripts

SLURM batch scripts are created in the run's output directory:
- `slurm_{run_id}.sh` - The batch script
- `slurm_{run_id}.out` - Standard output
- `slurm_{run_id}.err` - Standard error

## Status Flow

1. **Waiting (status_id: 1)**: Run is created and waiting to be submitted
2. **Running (status_id: 2)**: Run is submitted to SLURM and executing
3. **Completed (status_id: 3)**: Run completed successfully (set by `finish_run`)
4. **Failed (status_id: 4)**: Run failed or was cancelled

## Monitoring

The system monitors jobs by:
1. Checking `squeue` for active jobs
2. Falling back to `sacct` for completed jobs
3. Polling every 30 seconds until completion
4. Maximum of 480 attempts (4 hours at 30-second intervals)

## Benefits Over Previous System

1. **Resource Management**: SLURM handles CPU, memory, and time limits
2. **Job Queuing**: Automatic queuing when resources are unavailable
3. **Better Monitoring**: Standard SLURM tools for job tracking
4. **Scalability**: Can distribute jobs across multiple nodes
5. **Reliability**: SLURM handles job failures and retries
6. **Standard Tools**: Uses industry-standard HPC job scheduler

## Migration from Old System

The old `exec_runs.rake` task is no longer needed. Replace it with:
```bash
rails slurm:start_scheduler
```

Or use ActiveJob workers to process the job queue automatically.

## Troubleshooting

### Jobs Not Starting
- Check SLURM is installed and accessible: `which sbatch`
- Verify SLURM is running: `sinfo`
- Check job queue: `squeue`

### Jobs Stuck in Pending
- Check SLURM partition availability: `sinfo -l`
- Verify resource requests are reasonable
- Check SLURM logs: `/var/log/slurm/`

### Jobs Failing Immediately
- Check SLURM error files: `slurm_{run_id}.err`
- Verify command syntax in batch script
- Check file permissions on output directories

