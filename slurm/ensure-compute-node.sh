#!/bin/bash
# Verify Slurm compute (slurmd) is running so pending jobs can start.
set -euo pipefail

echo "=== Slurm controller ==="
systemctl is-active slurmctld 2>/dev/null || echo "slurmctld: not active"
echo ""
echo "=== Slurm compute (slurmd) ==="
if systemctl is-active slurmd >/dev/null 2>&1; then
  echo "slurmd: active"
else
  echo "slurmd: INACTIVE (jobs will stay pending with ReqNodeNotAvail)"
  echo "Fix: sudo systemctl enable --now slurmd"
fi
echo ""
echo "=== Nodes (sinfo) ==="
sinfo -Nel 2>/dev/null || sinfo -Nel
echo ""
echo "=== Pending jobs ==="
squeue -t PD -o '%.10i %.8u %.2t %.30r' 2>/dev/null || true
echo ""
if ! systemctl is-active slurmd >/dev/null 2>&1; then
  exit 1
fi
