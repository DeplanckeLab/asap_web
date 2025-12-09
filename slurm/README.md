# SLURM Configuration

This directory contains SLURM configuration files for the docker-compose setup.

## Files

- `slurm.conf` - Main SLURM configuration file
- `slurmdbd.conf` - SLURM database daemon configuration
- `cgroup.conf` - Cgroup configuration for resource limits

## Configuration Details

### Single-Node Cluster
- **Controller**: `slurmctld` container
- **Compute Node**: `slurmd` container  
- **Database**: `slurmdb` (MySQL) for accounting
- **Database Daemon**: `slurmdbd` for accounting storage

### Resource Limits
- **CPUs**: 90% of total system CPUs (automatically configured)
- **Memory**: 90% of total system RAM (automatically configured)
- **Partition**: `debug` (default partition)
- **Remaining**: 10% reserved for database and web app

To update resource limits, run:
```bash
./slurm/configure_resources.sh
```

This will automatically detect system resources and configure SLURM to use 90% of available CPU and RAM.

### Accessing SLURM

From the `website` container, you can access SLURM commands:
- `sbatch` - Submit jobs
- `squeue` - View job queue
- `scancel` - Cancel jobs
- `sinfo` - View cluster information

The SLURM services are accessible via hostnames:
- `slurmctld` - Controller
- `slurmd` - Compute node
- `slurmdbd` - Database daemon

## Updating Configuration

After modifying SLURM configuration files, restart the SLURM services:
```bash
docker-compose restart slurmctld slurmd slurmdbd
```

## Initialization

On first start, SLURM will initialize automatically. The database will be created automatically by the MySQL container.

