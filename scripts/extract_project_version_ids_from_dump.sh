#!/usr/bin/env bash
# Wrapper: extract id,key,version_id from a pg_dump plain SQL file.
# Default dump path matches the ASAP production snapshot naming used on this host.
#
# Usage:
#   ./scripts/extract_project_version_ids_from_dump.sh [dump.sql] > projects_version_id.csv
#   DUMP=/other/dump.sql ./scripts/extract_project_version_ids_from_dump.sh > out.csv

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DUMP="${1:-${DUMP:-/data/dumps/2026_05_06_asap_production3.sql}}"
exec python3 "$ROOT/scripts/extract_project_version_ids_from_dump.py" "$DUMP"
