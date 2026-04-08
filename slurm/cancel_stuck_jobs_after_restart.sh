#!/usr/bin/env bash
# Cancel Slurm jobs left in a bad pending state after slurmd or Docker/Compose restarts.
# Typical case: Reason contains launch_failed (e.g. slurmstepd EAGAIN); those jobs rarely recover without scancel.
#
# Usage (on the Slurm submit host, same environment as sbatch/squeue):
#   ./cancel_stuck_jobs_after_restart.sh           # list matching jobs only (dry run)
#   ./cancel_stuck_jobs_after_restart.sh --apply   # run scancel on each match
#
# Optional automation:
#   - systemd: ExecStartPost=.../cancel_stuck_jobs_after_restart.sh --apply on slurmd.service (see docs/SLURM_SETUP.md)
#   - after docker compose restart: run once on the host if Slurm clients run there

set -u

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing command: $1"
    exit 1
  fi
}

need_cmd squeue
need_cmd scancel

APPLY=0
if [ "${1:-}" = "--apply" ]; then
  APPLY=1
elif [ -n "${1:-}" ]; then
  echo "Usage: $0 [--apply]"
  exit 2
fi

# Pending jobs only; %i|%r avoids spaces in reason breaking the parser.
matches=$(squeue -h -t PENDING -o "%i|%r" 2>/dev/null | while IFS='|' read -r jid reason; do
  [ -z "${jid:-}" ] && continue
  norm=$(printf '%s' "$reason" | tr '[:upper:]' '[:lower:]' | tr ' ' '_')
  case "$norm" in
    *launch_failed*) printf '%s\n' "$jid" ;;
  esac
done | sort -u | tr '\n' ' ')

matches=${matches%% }

if [ -z "$matches" ]; then
  echo "$(date -Iseconds) No pending jobs with launch_failed in reason."
  exit 0
fi

echo "$(date -Iseconds) Pending jobs with launch_failed in reason: $matches"

if [ "$APPLY" -ne 1 ]; then
  echo "Dry run. Re-run with --apply to cancel these jobs."
  exit 0
fi

for jid in $matches; do
  echo "scancel $jid"
  scancel "$jid"
done

echo "$(date -Iseconds) Done."
