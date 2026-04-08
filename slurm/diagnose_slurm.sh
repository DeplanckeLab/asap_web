#!/usr/bin/env bash
# Read-only Slurm diagnostics. Run on a host that has Slurm client commands (sinfo, squeue, scontrol).
# Usage:
#   ./diagnose_slurm.sh              # cluster overview + pending reasons
#   ./diagnose_slurm.sh JOBID        # same + scontrol show job JOBID
#
# Typical use after switching to select/cons_tres: see whether nodes are schedulable
# and why jobs stay PD (Reason field).

set -u

JOBID="${1:-}"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing command: $1 (install Slurm client tools or run this on the controller/compute host)."
    exit 1
  fi
}

need_cmd sinfo
need_cmd squeue
need_cmd scontrol

echo "=== Slurm diagnose $(date -Iseconds) ==="
echo

echo "--- Controller / daemon ping ---"
scontrol ping 2>&1 || true
echo

echo "--- Key config (SelectType, accounting, scheduler) ---"
scontrol show config 2>&1 | grep -E '^(SelectType|AccountingStorage|SchedulerType|PriorityType|SchedulerParameters)' || true
echo

echo "--- Nodes (one line per node: NODELIST STATE CPUS MEMORY) ---"
sinfo -N -o "%N %T %c %m" 2>&1 || true
echo

echo "--- Partitions (PARTITION AVAIL TIMELIMIT NODES STATE CPUS MEMORY GRES) ---"
sinfo -o "%P %a %l %D %t %C %m %G" 2>&1 || true
echo

echo "--- Job counts by state ---"
squeue -h -o "%T" 2>&1 | sort | uniq -c || true
echo

echo "--- Running jobs (if any) ---"
squeue -t RUNNING -o "%.18i %.9P %.8u %.2t %.10M %D %R" 2>&1 | head -50
echo

echo "--- Pending jobs with reason (first 40 lines) ---"
squeue -t PENDING -o "%.18i %.9P %.8u %.2t %20r %50R" 2>&1 | head -40
echo

echo "--- scontrol show job (each pending job, up to 5) ---"
# Full job record: StdOut, StdErr, WorkDir, Command, TRES, and scheduler state (incl. launch failures).
pending_ids=$(squeue -h -t PENDING -o "%i" 2>/dev/null | head -5)
for jid in $pending_ids; do
  echo "... job $jid ..."
  scontrol show job "$jid" 2>&1 || true
  echo
done

if [ -n "$JOBID" ]; then
  echo "--- scontrol show job $JOBID ---"
  scontrol show job "$JOBID" 2>&1 || true
  echo
  echo "--- squeue for $JOBID ---"
  squeue -j "$JOBID" -o "%.18i %.2t %20R %30r %b" 2>&1 || true
  echo
fi

echo "--- Notes ---"
echo "Resources / ReqNodeNotAvail: job CPU/mem request does not fit node totals in slurm.conf (RealMemory, --mem in the batch script)."
echo "launch failed requeued held: the scheduler picked a node but slurmd could not start the job (script path, chdir, prolog, docker exec, permissions). Read StdErr from scontrol show job above; on the node: journalctl -u slurmd -b or /var/log/slurm/slurmd.log. After fixing, scancel and resubmit."
echo "Nodes DOWN/DRAIN/UNKNOWN: fix slurmd first; cons_tres cannot place jobs on unusable nodes."
echo "After changing SelectType: restart slurmctld and slurmd, not only scontrol reconfigure."
echo "Stuck pending with launch_failed: see slurm/cancel_stuck_jobs_after_restart.sh (dry run or --apply)."
echo
echo "Done."
