#!/bin/bash
# Script to check SLURM job status

echo "=== SLURM Cluster Status ==="
docker exec slurmctld sinfo

echo ""
echo "=== Job Queue (All Jobs) ==="
docker exec slurmctld squeue

echo ""
echo "=== Recent Job History ==="
docker exec slurmctld sacct --format=JobID,JobName,State,ExitCode,Elapsed,MaxRSS,AllocCPUS -S $(date -d '1 hour ago' +%Y-%m-%dT%H:%M:%S)

echo ""
echo "=== Detailed Job Information ==="
echo "To view details of a specific job, use:"
echo "  docker exec slurmctld scontrol show job <job_id>"
echo ""
echo "To view job output, check the slurm_*.out files in the project directories"

