# SLURM Docker Image

This directory contains a Dockerfile to build SLURM from Ubuntu packages.

## Building the Image

The Dockerfile installs SLURM from Ubuntu repositories, which is simpler than building from source.

## Configuration

The image uses:
- Ubuntu 22.04 as base
- SLURM packages from Ubuntu repositories
- Authentication disabled (auth/none) for simplicity in docker-compose setup

## Usage

The docker-compose.yml will automatically build this image when starting SLURM services:

```bash
docker-compose build slurmctld slurmd slurmdbd
```

Or start all services (will build automatically):
```bash
docker-compose up -d slurmdb slurmdbd slurmctld slurmd
```

