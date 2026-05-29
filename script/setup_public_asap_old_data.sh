#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PUBLIC_DATA="${REPO_ROOT}/src/public/data/asap-old"
SOURCE="${ASAP_OLD_INPUT_EXAMPLES:-/mnt/asap-old/input_examples}"

if [[ ! -d "$SOURCE" ]]; then
  echo "ERROR: Source directory does not exist: $SOURCE" >&2
  echo "Mount asap-old input_examples or set ASAP_OLD_INPUT_EXAMPLES." >&2
  exit 1
fi

mkdir -p "${PUBLIC_DATA}"
ln -sfn "$SOURCE" "${PUBLIC_DATA}/input_examples"
echo "Linked ${PUBLIC_DATA}/input_examples -> ${SOURCE}"
echo "URLs: https://asap-test.epfl.ch/data/asap-old/input_examples/<filename>"
