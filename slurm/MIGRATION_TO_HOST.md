# Migration Plan: Moving SLURM to Host Machine

## Overview
Moving slurmctld and slurmdbd from Docker containers to the host machine to resolve munge authentication issues, while keeping the Rails app and MySQL in Docker.

## Architecture

### On Host Machine:
- **slurmd** (already running) - Compute node daemon
- **slurmctld** (to be installed) - Controller daemon  
- **slurmdbd** (to be installed) - Database daemon
- **munge** (already running) - Authentication service

### In Docker:
- **slurmdb** (MySQL) - Accounting database
- **website** (Rails app) - With SLURM client tools installed
- Other services (postgres, redis, elasticsearch, etc.)

## Changes Made

### 1. Website Container (Docker)
- ✅ Added SLURM client tools installation in Dockerfile
- ✅ Mounted `slurm.conf.client` (points to host via host.docker.internal)
- ✅ Mounted `/etc/munge/munge.key` (read-only)
- ✅ Updated SlurmService to call `sbatch`/`squeue`/`scancel` directly
- ✅ Removed dependency on slurmctld container

### 2. Host Machine Setup
- ✅ Created `install-slurm-host.sh` script
- ✅ Script installs slurm-slurmctld and slurm-slurmdbd packages
- ✅ Configures slurm.conf and slurmdbd.conf for host
- ✅ Sets up systemd services

### 3. Configuration Files
- ✅ `slurm.conf` - For host (ControlMachine=hostname)
- ✅ `slurm.conf.client` - For website container (ControlMachine=host.docker.internal)
- ✅ `slurmdbd.conf` - Updated with AuthType=auth/munge

## Next Steps

### 1. Install SLURM on Host
```bash
sudo /path/to/your/checkout/slurm/install-slurm-host.sh
```

### 2. Verify Host Services
```bash
sudo systemctl status munge
sudo systemctl status slurmdbd
sudo systemctl status slurmctld
sinfo
squeue
```

### 3. Rebuild Website Container
```bash
docker-compose build website
docker-compose up -d website
```

### 4. Test from Website Container
```bash
docker exec website sbatch --version
docker exec website sinfo
```

### 5. Stop Docker SLURM Containers
```bash
docker-compose stop slurmctld slurmdbd
# Optionally remove from docker-compose.yml
```

## Benefits

1. **Resolves munge authentication** - Everything runs in same systemd environment
2. **Simpler architecture** - No Docker networking issues
3. **Better performance** - No Docker exec overhead
4. **Easier debugging** - Standard systemd logs and tools
5. **Version consistency** - Host and containers use same SLURM version

## Troubleshooting

### If website container can't connect to host slurmctld:
- Check `host.docker.internal` resolves: `docker exec website ping host.docker.internal`
- Verify host firewall allows port 6817
- Check slurm.conf.client has correct ControlMachine

### If munge authentication fails:
- Verify munge.key is identical on host and in container
- Check munge service is running on host: `sudo systemctl status munge`
- Verify time synchronization

### If slurmdbd can't connect to MySQL:
- Check MySQL container IP: `docker inspect slurmdb`
- Verify slurmdbd.conf StorageHost points to correct IP
- Check MySQL allows connections from host

