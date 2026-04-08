# SLURM Integration Setup

This document describes the SLURM integration for the docker-compose environment.

**Restarting Compose or Slurm** (checklist, stuck jobs, verification): see **`RESTART_DOCKER_AND_SLURM.md`**.

**Adding compute nodes** (more concurrent jobs): see **`SLURM_ADD_COMPUTE_NODES.md`**. That is an operations task (extra machines, `slurmd`, shared `/data`, munge); it cannot be done from the Rails app alone.

## Overview

SLURM (Simple Linux Utility for Resource Management) has been integrated to manage parsing jobs and other compute-intensive tasks. This provides better resource management, job queuing, and prevents resource exhaustion.

## Architecture

The setup includes:

1. **slurmdb** - MySQL database for SLURM accounting
2. **slurmdbd** - SLURM database daemon
3. **slurmctld** - SLURM controller daemon (manages job queue)
4. **slurmd** - SLURM compute node daemon (executes jobs)

## Services

### SLURM Database (slurmdb)
- MySQL 8.0 container
- Stores job accounting information
- Database: `slurm_acct_db`
- User: `slurm` / Password: `slurm`

### SLURM Database Daemon (slurmdbd)
- Connects SLURM to MySQL database
- Handles accounting storage

### SLURM Controller (slurmctld)
- Manages job queue and scheduling
- Accepts job submissions via `sbatch`
- Monitors job status

### SLURM Compute Node (slurmd)
- Executes submitted jobs
- Reports resource usage
- Runs with privileged mode for cgroup support

## Configuration

Configuration files are in `/srv/asap2_test/slurm/`:

- `slurm.conf` - Main SLURM configuration
- `slurmdbd.conf` - Database daemon configuration
- `cgroup.conf` - Resource limits configuration

### Resource Allocation

SLURM is configured to use **90% of total system resources**, leaving **10% for database and web app**.

**Current Configuration** (auto-detected):
- **Total CPUs**: 144
- **Total RAM**: ~754GB
- **SLURM Allocation**: 129 CPUs, ~678GB RAM
- **Reserved for DB/Web**: 15 CPUs, ~77GB RAM

To reconfigure resources, run:
```bash
cd /srv/asap2_test
./slurm/configure_resources.sh
docker-compose restart slurmctld slurmd
```

The script automatically detects system resources and updates `slurm.conf` accordingly.

## How It Works

1. **Job Submission**: The Rails application (`SlurmService`) submits jobs via `docker exec slurmctld sbatch`
2. **Job Execution**: SLURM schedules and executes jobs on the `slurmd` container
3. **Job Monitoring**: `SlurmJobMonitorJob` monitors job status via `docker exec slurmctld squeue/sacct`
4. **Job Completion**: When jobs complete, `SlurmJobMonitorJob` calls `Basic.finish_run` to update status

## Starting SLURM

```bash
docker-compose up -d slurmdb slurmdbd slurmctld slurmd
```

## Verifying SLURM

Check SLURM status:
```bash
# View cluster info
docker exec slurmctld sinfo

# View job queue
docker exec slurmctld squeue

# View job accounting
docker exec slurmctld sacct
```

## Troubleshooting

### SLURM services not starting
1. Check logs: `docker-compose logs slurmctld slurmd slurmdbd`
2. Verify MySQL is healthy: `docker-compose ps slurmdb`
3. Check configuration files in `slurm/` directory

### Jobs not executing
1. Verify slurmd is registered: `docker exec slurmctld sinfo`
2. Check slurmd logs: `docker-compose logs slurmd`
3. Verify volumes are mounted correctly

### Permission issues
- Ensure script files are executable
- Check that volumes are mounted with correct permissions
- Verify slurmd has access to required directories

## Updating Configuration

After modifying SLURM configuration files:
```bash
docker-compose restart slurmctld slurmd slurmdbd
```

## Stuck jobs after slurmd or Compose restart

See **[RESTART_DOCKER_AND_SLURM.md](RESTART_DOCKER_AND_SLURM.md)** section 5 and the **`slurm/cancel_stuck_jobs_after_restart.sh`** helper (also documented there with optional **`systemd`** hook).

## Notes

- The `website` container accesses SLURM commands via `docker exec` to the `slurmctld` container
- All containers share the same volume mounts for data access
- Jobs execute in the `slurmd` container, which has access to docker socket for running docker commands
- The parsing rake task runs inside `slurmd` and uses docker internally for Java execution

