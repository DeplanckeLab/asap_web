#!/usr/bin/env bash
# Build fabdavid/asap_run for a patch version, retag major/latest, push to the registry,
# rebuild compose asap_run, and register the build in the development database.
#
# Usage:
#   ./build_asap_run.sh <version>
#   ./build_asap_run.sh 8.3
#   ./build_asap_run.sh v8.3
#
# Optional env:
#   ASAP_RUN_DIR   (default /srv/asap_run_new)
#   ASAP2_DIR      (default /srv/asap2_test)
#   IMAGE_NAME     (default fabdavid/asap_run)
#   SKIP_REGISTER=1  skip docker_builds:register rake
#   SKIP_COMPOSE=1   skip docker compose build/up of asap_run
#   SKIP_PUSH=1      skip docker push
#   FORCE=1          overwrite an existing local image without prompting

set -euo pipefail

usage() {
  echo "Usage: $0 <version>"
  echo "  Example: $0 8.3   or   $0 v8.3"
  echo ""
  echo "Builds ${IMAGE_NAME:-fabdavid/asap_run}:vX.Y from Dockerfile.vX.Y,"
  echo "tags :latest and :vX, pushes them, rebuilds compose asap_run, and registers DockerBuild."
  exit 1
}

confirm_yes() {
  local prompt="$1"
  local answer=""
  if [[ ! -t 0 ]]; then
    echo "Non-interactive stdin: refusing without confirmation."
    echo "Re-run with a TTY, or set FORCE=1 to overwrite."
    return 1
  fi
  read -r -p "${prompt} [y/N] " answer
  case "${answer}" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

VERSION_RAW="${1:-}"
if [[ -z "${VERSION_RAW}" ]]; then
  usage
fi

ASAP_RUN_DIR="${ASAP_RUN_DIR:-/srv/asap_run_new}"
ASAP2_DIR="${ASAP2_DIR:-/srv/asap2_test}"
IMAGE_NAME="${IMAGE_NAME:-fabdavid/asap_run}"

VERSION_NUM="${VERSION_RAW#v}"
if [[ ! "${VERSION_NUM}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
  echo "Invalid version: ${VERSION_RAW}"
  echo "Expected forms: 8, 8.3, v8, v8.3"
  exit 1
fi

PATCH_TAG="v${VERSION_NUM}"
MAJOR_TAG="v${VERSION_NUM%%.*}"
DOCKERFILE_NAME="Dockerfile.${PATCH_TAG}"
DOCKERFILE_PATH="${ASAP_RUN_DIR}/${DOCKERFILE_NAME}"
IMAGE_REF_MAJOR="${IMAGE_NAME}:${MAJOR_TAG}"
IMAGE_REF_PATCH="${IMAGE_NAME}:${PATCH_TAG}"
IMAGE_REF_LATEST="${IMAGE_NAME}:latest"

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

confirm_overwrite_existing_images() {
  if [[ "${FORCE:-0}" == "1" ]]; then
    echo "FORCE=1: overwriting existing local tags if present."
    return 0
  fi

  local existing=()
  local ref
  for ref in "${IMAGE_REF_PATCH}" "${IMAGE_REF_MAJOR}" "${IMAGE_REF_LATEST}"; do
    if docker image inspect "${ref}" >/dev/null 2>&1; then
      existing+=("${ref}")
    fi
  done

  if [[ ${#existing[@]} -eq 0 ]]; then
    return 0
  fi

  echo "Local image tag(s) already exist and would be rewritten:"
  local id
  for ref in "${existing[@]}"; do
    id="$(docker image inspect --format '{{.Id}}' "${ref}" 2>/dev/null || echo unknown)"
    echo "  ${ref}  (${id})"
  done
  echo ""

  if confirm_yes "Overwrite these image tag(s) and continue the build?"; then
    return 0
  fi

  echo "Aborted."
  exit 1
}

ensure_dockerfile
confirm_overwrite_existing_images

echo "Building ${IMAGE_REF_PATCH} from ${DOCKERFILE_PATH}"
cd "${ASAP_RUN_DIR}"
docker build -t "${IMAGE_REF_PATCH}" -f "${DOCKERFILE_PATH}" ./ 2>&1 | tee build.log

echo "Tagging ${IMAGE_REF_PATCH} as ${IMAGE_REF_LATEST} and ${IMAGE_REF_MAJOR}"
docker tag "${IMAGE_REF_PATCH}" "${IMAGE_REF_LATEST}"
docker tag "${IMAGE_REF_PATCH}" "${IMAGE_REF_MAJOR}"

if [[ "${SKIP_PUSH:-0}" != "1" ]]; then
  echo "Pushing ${IMAGE_REF_PATCH}, ${IMAGE_REF_MAJOR}, and ${IMAGE_REF_LATEST}"
  docker push "${IMAGE_REF_PATCH}"
  docker push "${IMAGE_REF_MAJOR}"
  docker push "${IMAGE_REF_LATEST}"
fi

if [[ "${SKIP_COMPOSE:-0}" != "1" ]]; then
  echo "Rebuilding compose asap_run with ${DOCKERFILE_NAME}"
  cd "${ASAP2_DIR}"
  export ASAP_RUN_DOCKERFILE="${DOCKERFILE_NAME}"
  docker-compose build asap_run
  docker-compose up -d asap_run
fi

if [[ "${SKIP_REGISTER:-0}" != "1" ]]; then
  echo "Registering DockerBuild for ${IMAGE_REF_MAJOR} in development DB"
  cd "${ASAP2_DIR}"
  docker-compose exec -T website \
    bundle exec rake docker_builds:register \
    "IMAGE_REF=${IMAGE_REF_MAJOR}" \
    "PATCH_TAG=${PATCH_TAG}"
fi

echo "Done: ${IMAGE_REF_PATCH} (major ${IMAGE_REF_MAJOR})"
