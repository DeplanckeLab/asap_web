# SLURM Configuration

This directory contains SLURM configuration files for the docker-compose setup.

## Files

Production-specific `slurm.conf`, `slurm.conf.client`, `slurmdbd.conf`, and several host install scripts are **gitignored**. Use the tracked templates:

- `slurm.conf.example`, `slurm.conf.client.example`, `slurmdbd.conf.example`
- `install-slurm-host.sh.example`, `fresh-install-slurm-host.sh.example`, `init-slurm-database-direct.sh.example`

Copy each to the matching name **without** `.example`, edit hostnames and secrets, then keep those copies local or in a private ops repo.

- `cgroup.conf` - Cgroup configuration for resource limits

## Configuration Details

### Cluster layout
- **Controller**: `slurmctld` (often on the host; see `MIGRATION_TO_HOST.md`)
- **Compute nodes**: `slurmd` on each execution host
- **Database**: MySQL for Slurm accounting (`slurmdbd`)
- **Scaling**: To run more jobs in parallel, add hosts and register them in `slurm.conf`; see **`docs/SLURM_ADD_COMPUTE_NODES.md`**.

### Legacy single-container layout (reference)
- Older docs referred to `slurmctld` / `slurmd` **containers**; production may use host `slurmd` instead.

### Resource Limits
Templates ship with placeholder node sizing; tune `CPUs`, `RealMemory`, and partitions for each host.

- **CPUs**: Often set to ~90% of total system CPUs when using `./slurm/configure_resources.sh`
- **Memory**: Size `RealMemory` (MB) per node line to fit your hosts; `./slurm/configure_resources.sh` can suggest values on the machine where you run it
- **Partition**: `debug` (default partition) in templates
- **Remaining capacity**: Leave headroom on the controller node for databases and web services

To regenerate resource knobs on the current machine, run:
```bash
./slurm/configure_resources.sh
```
Review the resulting local `slurm.conf` before deploying to `/etc/slurm`.

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

