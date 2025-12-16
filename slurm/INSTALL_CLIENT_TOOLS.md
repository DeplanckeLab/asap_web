# Installing SLURM Client Tools in Website Container

## Overview
To use slurmctld running on the host from the Rails app in Docker, we need to:
1. Install SLURM client tools in the website container
2. Configure them to connect to slurmctld on the host
3. Share munge key and slurm.conf

## Steps

### 1. Update Dockerfile
Add SLURM client tools installation (build from source to match version 22.05.9):

```dockerfile
# Install SLURM client tools (sbatch, squeue, scancel, sacct)
# Build from source to match host version 22.05.9
RUN apt-get update && apt-get install -y --no-install-recommends \
    libmunge-dev libmunge2 munge \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /tmp
RUN wget https://download.schedmd.com/slurm/slurm-22.05.9.tar.bz2 && \
    tar -xjf slurm-22.05.9.tar.bz2 && \
    cd slurm-22.05.9 && \
    ./configure --prefix=/usr/local/slurm \
                 --sysconfdir=/etc/slurm \
                 --enable-pam \
                 --disable-cgroup \
                 --without-shared-libslurm \
                 --disable-shared && \
    make -j$(nproc) && \
    make install && \
    cd / && \
    rm -rf /tmp/slurm-22.05.9* && \
    ldconfig

ENV PATH=/usr/local/slurm/bin:$PATH
```

### 2. Update docker-compose.yml
Mount slurm.conf and munge.key into website container:

```yaml
website:
  volumes:
    - ./slurm/slurm.conf:/etc/slurm/slurm.conf:ro
    - /etc/munge/munge.key:/etc/munge/munge.key:ro
  environment:
    - SLURM_CONF_FILE=/etc/slurm/slurm.conf
```

### 3. Update slurm.conf for host connection
Set ControlMachine to host.docker.internal or host IP.

### 4. Update SlurmService
Change from `docker exec slurmctld sbatch` to direct `sbatch` calls:
- `sbatch --parsable #{script_file}`
- `squeue -j #{slurm_job_id}`
- `scancel #{slurm_job_id}`

## Benefits
- No Docker exec overhead
- Direct connection to host slurmctld
- Same munge authentication as host
- Simpler architecture

