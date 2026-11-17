#!/usr/bin/env bash
# Build fabdavid/asap_run:vX.Y for TESTING ON DEV: build, push the patch tag, register the
# DockerBuild in the development database and pin dev to it (docker_images.runtime_tag,
# which Rails uses for every docker run; plus the dev compose asap_run service).
#
# This script never moves :vX (e.g. :v8) or :latest and never touches prod: dev and prod
# share this docker daemon and Docker Hub, so moving :v8 would silently switch prod too.
# Release a tested build to prod with reference_data:steps_std_methods:sync_from_dev
# (copies the pin and the DockerBuild, rebuilds prod compose asap_run), then optionally
# ./retag_asap_run_major.sh to move :vX / :latest on Docker Hub.
#
# Usage:
#   ./build_asap_run.sh <patch version>
#   ./build_asap_run.sh 8.3
#   ./build_asap_run.sh v8.3
#
# Optional env:
#   ASAP_RUN_DIR   (default /srv/asap_run_new)
#   ASAP2_DIR      (default /srv/asap2_test)  # dev instance
#   IMAGE_NAME     (default fabdavid/asap_run)
#   SKIP_REGISTER=1  skip docker_builds:register rake
#   SKIP_PIN=1       register the build without pinning dev to it (dev keeps its current pin)
#   SKIP_COMPOSE=1   skip the dev compose asap_run Dockerfile edit and rebuild
#   SKIP_PUSH=1      skip docker push
#   FORCE=1          overwrite an existing local patch tag without prompting;
#                    also skips the DockerBuild replace prompt (including non-operator usage)
#   ALLOW_REPLACE    set automatically by this script after replace confirmation

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=asap_run_common.sh
source "${SCRIPT_DIR}/asap_run_common.sh"

usage() {
  echo "Usage: $0 <patch version>"
  echo "  Example: $0 8.3   or   $0 v8.3"
  echo ""
  echo "Builds ${IMAGE_NAME:-fabdavid/asap_run}:vX.Y from Dockerfile.vX.Y, pushes that tag,"
  echo "registers the DockerBuild in the dev database and pins dev to it."
  echo "Does not move :vX or :latest and does not touch prod (promote with sync_from_dev)."
  exit 1
}

VERSION_RAW="${1:-}"
if [[ -z "${VERSION_RAW}" ]]; then
  usage
fi

ASAP_RUN_DIR="${ASAP_RUN_DIR:-/srv/asap_run_new}"
ASAP2_DIR="${ASAP2_DIR:-/srv/asap2_test}"
IMAGE_NAME="${IMAGE_NAME:-fabdavid/asap_run}"

parse_version_arg "${VERSION_RAW}" patch_only
DOCKERFILE_NAME="Dockerfile.${PATCH_TAG}"
DOCKERFILE_PATH="${ASAP_RUN_DIR}/${DOCKERFILE_NAME}"
IMAGE_REF_PATCH="${IMAGE_NAME}:${PATCH_TAG}"

if [[ ! -d "${ASAP_RUN_DIR}" ]]; then
  echo "ASAP_RUN_DIR does not exist: ${ASAP_RUN_DIR}"
  exit 1
fi

ensure_dockerfile() {
  if [[ -f "${DOCKERFILE_PATH}" ]]; then
    return 0
  fi

  echo "Dockerfile is missing: ${DOCKERFILE_PATH}"
  echo ""

  local candidates=()
  local f
  for f in "${ASAP_RUN_DIR}"/Dockerfile."${MAJOR_TAG}".* "${ASAP_RUN_DIR}/Dockerfile.${MAJOR_TAG}"; do
    [[ -f "${f}" ]] || continue
    [[ "$(basename "${f}")" == "${DOCKERFILE_NAME}" ]] && continue
    candidates+=("${f}")
  done

  local source=""
  if [[ ${#candidates[@]} -gt 0 ]]; then
    # Prefer highest existing patch Dockerfile for this major (lexical on vX.Y names).
    source="$(printf '%s\n' "${candidates[@]}" | sort -V | tail -n 1)"
    echo "Latest existing Dockerfile for ${MAJOR_TAG}: $(basename "${source}")"
  fi

  if [[ -t 0 ]]; then
    if [[ -n "${source}" ]]; then
      if confirm_yes "Copy $(basename "${source}") to ${DOCKERFILE_NAME} so you can edit it?"; then
        cp "${source}" "${DOCKERFILE_PATH}"
        echo "Created ${DOCKERFILE_PATH}"
        echo "Edit it as needed, then re-run: $0 ${VERSION_RAW}"
        exit 0
      fi
    else
      if confirm_yes "No prior Dockerfile found for ${MAJOR_TAG}. Create an empty ${DOCKERFILE_NAME}?"; then
        touch "${DOCKERFILE_PATH}"
        echo "Created empty ${DOCKERFILE_PATH}"
        echo "Fill it in, then re-run: $0 ${VERSION_RAW}"
        exit 0
      fi
    fi
  fi

  echo "Add ${DOCKERFILE_NAME} under ${ASAP_RUN_DIR}, then re-run:"
  echo "  $0 ${VERSION_RAW}"
  exit 1
}

confirm_overwrite_existing_image() {
  if ! docker image inspect "${IMAGE_REF_PATCH}" >/dev/null 2>&1; then
    return 0
  fi
  if [[ "${FORCE:-0}" == "1" ]]; then
    echo "FORCE=1: overwriting existing local tag ${IMAGE_REF_PATCH}."
    return 0
  fi

  local id
  id="$(docker image inspect --format '{{.Id}}' "${IMAGE_REF_PATCH}" 2>/dev/null || echo unknown)"
  echo "Local image tag already exists and would be rewritten:"
  echo "  ${IMAGE_REF_PATCH}  (${id})"
  echo ""

  if confirm_yes "Overwrite this image tag and continue the build?"; then
    return 0
  fi

  echo "Aborted."
  exit 1
}

# Ask before rebuilding when a DockerBuild row already exists for this patch tag (vX.Y).
# Replace overwrites that row's fingerprint in place (row kept). Always reports per-user
# run counts (sandbox / anonymous counted as user "guest"). Guest or non-operator usage
# is warned, then can be bypassed after confirmation (or FORCE=1).
confirm_replace_existing_docker_build() {
  if [[ "${SKIP_REGISTER:-0}" == "1" ]]; then
    return 0
  fi

  ALLOW_REPLACE=0

  local report
  report="$(
    cd "${ASAP2_DIR}"
    docker-compose exec -T website \
      bundle exec rails runner \
      "builds = DockerBuild.where(tag: '${PATCH_TAG}').order(:id).to_a
       if builds.empty?
         puts 'NONE'
       else
         blocked = 0
         usage = Hash.new(0)
         builds.each do |b|
           blockers = b.replace_blockers
           refs = b.reference_count
           b.usage_by_user.each { |user, n| usage[user] += n }
           if blockers.any?
             blocked += 1
             puts ['BLOCK', b.id, b.digest, refs, blockers.join(' | ')].join(\"\\t\")
           else
             puts ['ROW', b.id, b.digest, refs].join(\"\\t\")
           end
         end
         usage.sort_by { |user, _n| user }.each do |user, n|
           puts ['USER', user, n].join(\"\\t\")
         end
         puts(blocked.positive? ? 'BLOCKED' : 'REPLACEABLE')
       end" 2>/dev/null
  )"
  report="$(printf '%s\n' "${report}" | tr -d '\r' | grep -E '^(NONE|ROW|BLOCK|USER|BLOCKED|REPLACEABLE)' || true)"

  if [[ -z "${report}" ]]; then
    echo "Failed to query DockerBuild rows for ${PATCH_TAG} in development DB."
    exit 1
  fi

  if printf '%s\n' "${report}" | grep -qx 'NONE'; then
    return 0
  fi

  local status
  status="$(printf '%s\n' "${report}" | grep -E '^(BLOCKED|REPLACEABLE)$' | tail -n 1)"

  echo "DockerBuild already exists for ${PATCH_TAG}:"
  printf '%s\n' "${report}" | grep -E '^(ROW|BLOCK)' | while IFS=$'\t' read -r kind build_id digest refs rest; do
    if [[ "${kind}" == "BLOCK" ]]; then
      echo "  id=${build_id}  digest=${digest}  refs=${refs}"
      echo "    non-operator usage: ${rest}"
    else
      echo "  id=${build_id}  digest=${digest}  refs=${refs}"
    fi
  done

  echo "  Runs by user:"
  local have_user=0
  while IFS=$'\t' read -r _kind user count; do
    have_user=1
    echo "    ${user}: ${count}"
  done < <(printf '%s\n' "${report}" | grep -E '^USER' || true)
  if [[ "${have_user}" -eq 0 ]]; then
    echo "    (none)"
  fi
  echo ""

  if [[ "${status}" == "BLOCKED" ]]; then
    echo "Warning: ${PATCH_TAG} was used by guest or users other than operators/admins."
    echo "Confirming will overwrite the fingerprint anyway (provenance stays on this row)."
    echo ""
  fi

  if [[ "${FORCE:-0}" == "1" ]]; then
    echo "FORCE=1: will overwrite ${PATCH_TAG} fingerprint on the existing DockerBuild row."
    ALLOW_REPLACE=1
    return 0
  fi

  local prompt
  if [[ "${status}" == "BLOCKED" ]]; then
    prompt="Bypass and replace this ${PATCH_TAG} by this new build (overwrite fingerprint on existing row)?"
  else
    prompt="Replace this ${PATCH_TAG} by this new build (overwrite fingerprint on existing row)?"
  fi

  if confirm_yes "${prompt}"; then
    ALLOW_REPLACE=1
    return 0
  fi

  echo "Cancelled."
  exit 1
}

ensure_dockerfile
confirm_overwrite_existing_image
ALLOW_REPLACE=0
confirm_replace_existing_docker_build

echo "Building ${IMAGE_REF_PATCH} from ${DOCKERFILE_PATH}"
cd "${ASAP_RUN_DIR}"
docker build -t "${IMAGE_REF_PATCH}" -f "${DOCKERFILE_PATH}" ./ 2>&1 | tee build.log

if [[ "${SKIP_PUSH:-0}" != "1" ]]; then
  echo "Pushing ${IMAGE_REF_PATCH}"
  docker push "${IMAGE_REF_PATCH}"
fi

PIN=0
if [[ "${SKIP_PIN:-0}" != "1" ]]; then
  current_pin="$(db_runtime_tag "${ASAP2_DIR}" "${IMAGE_NAME}" "${MAJOR_TAG}")"
  echo ""
  echo "Dev currently runs ${IMAGE_NAME}:${current_pin:-${MAJOR_TAG}} for ${MAJOR_TAG} projects."
  if [[ "${FORCE:-0}" == "1" ]] || confirm_yes "Pin dev to ${PATCH_TAG} (docker_images.runtime_tag in the dev DB)?"; then
    PIN=1
  else
    echo "Dev pin left at ${current_pin:-${MAJOR_TAG}}."
  fi
fi

if [[ "${SKIP_REGISTER:-0}" != "1" ]]; then
  register_docker_build "${ASAP2_DIR}" "${IMAGE_REF_PATCH}" "${PATCH_TAG}" "${ALLOW_REPLACE:-0}" "${PIN}"
elif [[ "${PIN}" == "1" ]]; then
  echo "SKIP_REGISTER=1: dev not pinned (pinning goes through docker_builds:register PIN=1)."
  PIN=0
fi

if [[ "${PIN}" == "1" && "${SKIP_COMPOSE:-0}" != "1" ]]; then
  echo "Rebuilding dev compose asap_run from ${DOCKERFILE_NAME}"
  rebuild_compose_asap_run "${ASAP2_DIR}" "${DOCKERFILE_NAME}"
fi

if [[ "${PIN}" == "1" ]]; then
  echo "Done: ${IMAGE_REF_PATCH} built and pinned on dev."
else
  echo "Done: ${IMAGE_REF_PATCH} built (dev not pinned to it)."
fi
echo "Prod and :${MAJOR_TAG} / :latest are unchanged. When tested, promote with sync_from_dev, then:"
echo "  ${SCRIPT_DIR}/retag_asap_run_major.sh ${MAJOR_TAG}"
