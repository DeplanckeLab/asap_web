#!/usr/bin/env bash
#
# Slurm healthcheck: verifies that the slurmdb container and host daemons
# (slurmdbd, slurmctld, slurmd) are running and attempts to restart any that
# are down. Intended to run from a systemd timer or cron.
#
# Usage:
#   ./slurm_healthcheck.sh                # check + restart
#   ./slurm_healthcheck.sh --dry-run      # check only, no restart
#
# Exit codes:
#   0 = all healthy (or successfully restarted)
#   1 = something is still unhealthy after restart attempt

set -u

COMPOSE_DIR="/srv/asap"
COMPOSE_FILE="docker-compose.prod.yml"
LOG_TAG="slurm-healthcheck"
DRY_RUN=false

if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
fi

log() {
  logger -t "$LOG_TAG" "$*"
  echo "$(date '+%Y-%m-%d %H:%M:%S') $*"
}

had_failure=false

# --- 1. slurmdb container (MySQL) ---
slurmdb_healthy=true
if ! docker-compose -f "$COMPOSE_DIR/$COMPOSE_FILE" ps --format '{{.Service}} {{.State}}' 2>/dev/null | grep -q '^slurmdb.*running'; then
  slurmdb_healthy=false
  log "slurmdb container is NOT running"
  if ! $DRY_RUN; then
    log "Starting slurmdb container..."
    docker-compose -f "$COMPOSE_DIR/$COMPOSE_FILE" up -d slurmdb
    sleep 10
    if docker-compose -f "$COMPOSE_DIR/$COMPOSE_FILE" ps --format '{{.Service}} {{.State}}' 2>/dev/null | grep -q '^slurmdb.*running'; then
      log "slurmdb container started successfully"
      slurmdb_healthy=true
    else
      log "slurmdb container failed to start"
      had_failure=true
    fi
  else
    had_failure=true
  fi
fi

# --- 2. slurmdbd ---
if ! systemctl is-active --quiet slurmdbd; then
  log "slurmdbd is NOT running"
  if ! $DRY_RUN; then
    if ! $slurmdb_healthy; then
      log "Skipping slurmdbd restart: slurmdb container is not healthy"
      had_failure=true
    else
      log "Starting slurmdbd..."
      systemctl start slurmdbd
      sleep 2
      if systemctl is-active --quiet slurmdbd; then
        log "slurmdbd started successfully"
      else
        log "slurmdbd failed to start (check: journalctl -u slurmdbd)"
        had_failure=true
      fi
    fi
  else
    had_failure=true
  fi
else
  # slurmdbd is running but verify it can actually talk to MySQL
  if ! sacct --noheader -S now 2>/dev/null; then
    log "slurmdbd is running but sacct cannot reach accounting database"
    if ! $DRY_RUN; then
      log "Restarting slurmdbd..."
      systemctl restart slurmdbd
      sleep 3
      if sacct --noheader -S now 2>/dev/null; then
        log "slurmdbd restarted and sacct works"
      else
        log "slurmdbd restarted but sacct still failing"
        had_failure=true
      fi
    else
      had_failure=true
    fi
  fi
fi

# --- 3. slurmctld ---
if ! systemctl is-active --quiet slurmctld; then
  log "slurmctld is NOT running"
  if ! $DRY_RUN; then
    log "Starting slurmctld..."
    systemctl start slurmctld
    sleep 2
    if systemctl is-active --quiet slurmctld; then
      log "slurmctld started successfully"
    else
      log "slurmctld failed to start (check: journalctl -u slurmctld)"
      had_failure=true
    fi
  else
    had_failure=true
  fi
fi

# --- 4. slurmd ---
if ! systemctl is-active --quiet slurmd; then
  log "slurmd is NOT running"
  if ! $DRY_RUN; then
    log "Starting slurmd..."
    systemctl start slurmd
    sleep 2
    if systemctl is-active --quiet slurmd; then
      log "slurmd started successfully"
    else
      log "slurmd failed to start (check: journalctl -u slurmd)"
      had_failure=true
    fi
  else
    had_failure=true
  fi
fi

# --- 5. Node state: resume if down ---
if ! $DRY_RUN && systemctl is-active --quiet slurmctld; then
  node_state=$(sinfo -h -N -o "%T" 2>/dev/null | head -1)
  if [[ "$node_state" == *"down"* || "$node_state" == *"drain"* ]]; then
    log "Node state is '$node_state', resuming..."
    scontrol update NodeName=updeplasrv4-new.epfl.ch State=RESUME 2>/dev/null
    sleep 1
    new_state=$(sinfo -h -N -o "%T" 2>/dev/null | head -1)
    log "Node state after resume: $new_state"
  fi
fi

# --- Summary ---
if $had_failure; then
  log "Healthcheck completed with failures"
  exit 1
else
  log "Healthcheck passed: all Slurm services are healthy"
  exit 0
fi
