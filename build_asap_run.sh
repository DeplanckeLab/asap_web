#!/usr/bin/env bash
# Build fabdavid/asap_run for a patch version, retag major/latest, push to the registry,
# point dev/prod compose at that Dockerfile, rebuild compose asap_run, and register the
# build in the development database.
#
# Usage:
#   ./build_asap_run.sh <version>
#   ./build_asap_run.sh 8.3
#   ./build_asap_run.sh v8.3
#
# Optional env:
#   ASAP_RUN_DIR   (default /srv/asap_run_new)
#   ASAP2_DIR      (default /srv/asap2_test)  # dev instance
#   ASAP_DIR       (default /srv/asap)       # prod instance
#   IMAGE_NAME     (default fabdavid/asap_run)
#   SKIP_REGISTER=1  skip docker_builds:register rake
#   SKIP_COMPOSE=1   skip compose dockerfile edit and asap_run rebuild
#   SKIP_PUSH=1      skip docker push
#   FORCE=1          overwrite existing local image tags without prompting;
#                    also skips the DockerBuild replace prompt when replace is allowed
#   ALLOW_REPLACE    set automatically by this script after replace confirmation

set -euo pipefail

usage() {
  echo "Usage: $0 <version>"
  echo "  Example: $0 8.3   or   $0 v8.3"
  echo ""
  echo "Builds ${IMAGE_NAME:-fabdavid/asap_run}:vX.Y from Dockerfile.vX.Y,"
  echo "tags :latest and :vX, pushes them, updates docker-compose asap_run dockerfile"
  echo "in dev and prod (after confirmation), rebuilds compose asap_run, and registers DockerBuild."
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
ASAP_DIR="${ASAP_DIR:-/srv/asap}"
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

# Ask before rebuilding when a DockerBuild row already exists for this patch tag (vX.Y).
# Replace overwrites that row's fingerprint in place (row kept). Allowed only when every
# existing row was unused, or only used by operators / ADMIN_EMAILS. Guest or other-user
# usage rejects immediately (no prompt).
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
         builds.each do |b|
           blockers = b.replace_blockers
           refs = b.reference_count
           if blockers.any?
             blocked += 1
             puts ['BLOCK', b.id, b.digest, refs, blockers.join(' | ')].join(\"\\t\")
           else
             puts ['ROW', b.id, b.digest, refs].join(\"\\t\")
           end
         end
         puts(blocked.positive? ? 'BLOCKED' : 'REPLACEABLE')
       end" 2>/dev/null
  )"
  report="$(printf '%s\n' "${report}" | tr -d '\r' | grep -E '^(NONE|ROW|BLOCK|BLOCKED|REPLACEABLE)' || true)"

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
      echo "    blocked by: ${rest}"
    else
      echo "  id=${build_id}  digest=${digest}  refs=${refs}"
    fi
  done
  echo ""

  if [[ "${status}" == "BLOCKED" ]]; then
    echo "Replace refused: ${PATCH_TAG} was used by guest users or users other than operators/admins."
    echo "Use a new patch version."
    exit 1
  fi

  if [[ "${FORCE:-0}" == "1" ]]; then
    echo "FORCE=1: will overwrite ${PATCH_TAG} fingerprint on the existing DockerBuild row."
    ALLOW_REPLACE=1
    return 0
  fi

  if confirm_yes "Replace this ${PATCH_TAG} by this new build (overwrite fingerprint on existing row)?"; then
    ALLOW_REPLACE=1
    return 0
  fi

  echo "Cancelled."
  exit 1
}

# Resolve compose file path for an instance (follow docker-compose.yml symlink when present).
compose_file_for_instance() {
  local instance_dir="$1"
  local compose="${instance_dir}/docker-compose.yml"
  if [[ -L "${compose}" ]]; then
    local target
    target="$(readlink "${compose}")"
    if [[ "${target}" != /* ]]; then
      target="${instance_dir}/${target}"
    fi
    printf '%s\n' "${target}"
    return 0
  fi
  if [[ -f "${compose}" ]]; then
    printf '%s\n' "${compose}"
    return 0
  fi
  echo "No docker-compose.yml in ${instance_dir}" >&2
  return 1
}

# Current asap_run dockerfile declaration (first non-comment dockerfile: line).
current_asap_run_dockerfile_line() {
  local compose_file="$1"
  grep -E '^[[:space:]]*dockerfile:' "${compose_file}" | head -n 1 || true
}

# Rewrite asap_run dockerfile to DOCKERFILE_NAME.
# Supports both:
#   dockerfile: Dockerfile.vX.Y
#   dockerfile: ${ASAP_RUN_DOCKERFILE:-Dockerfile.vX.Y}
update_asap_run_dockerfile_in_compose() {
  local compose_file="$1"
  local dockerfile_name="$2"
  local before after

  if [[ ! -f "${compose_file}" ]]; then
    echo "Compose file not found: ${compose_file}"
    return 1
  fi

  before="$(current_asap_run_dockerfile_line "${compose_file}")"
  if [[ -z "${before}" ]]; then
    echo "No active dockerfile: line found in ${compose_file}"
    return 1
  fi

  if ! grep -Eq '^[[:space:]]*dockerfile:.*Dockerfile\.v[0-9]' "${compose_file}"; then
    echo "Unexpected dockerfile line in ${compose_file}:"
    echo "  ${before}"
    return 1
  fi

  # Prefer updating the ${ASAP_RUN_DOCKERFILE:-...} default when present; else plain dockerfile.
  if grep -Eq '^[[:space:]]*dockerfile:[[:space:]]*\$\{ASAP_RUN_DOCKERFILE:-Dockerfile\.v[0-9][^}]*\}' "${compose_file}"; then
    sed -i -E \
      "s|^([[:space:]]*dockerfile:[[:space:]]*\\\$\{ASAP_RUN_DOCKERFILE:-)Dockerfile\.v[0-9][^}]*(\})|\1${dockerfile_name}\2|" \
      "${compose_file}"
  else
    sed -i -E \
      "s|^([[:space:]]*dockerfile:[[:space:]]*)Dockerfile\.v[0-9][^[:space:]]*|\1${dockerfile_name}|" \
      "${compose_file}"
  fi

  after="$(current_asap_run_dockerfile_line "${compose_file}")"
  if [[ "${after}" != *"${dockerfile_name}"* ]]; then
    echo "Failed to set dockerfile to ${dockerfile_name} in ${compose_file}"
    echo "  before: ${before}"
    echo "  after:  ${after}"
    return 1
  fi

  echo "Updated ${compose_file}"
  echo "  ${before}"
  echo "  -> ${after}"
}

update_compose_and_rebuild_asap_run() {
  local instances=("${ASAP2_DIR}" "${ASAP_DIR}")
  local instance compose_files=() compose labels=()
  local i

  for instance in "${instances[@]}"; do
    if [[ ! -d "${instance}" ]]; then
      echo "Instance directory missing: ${instance}"
      return 1
    fi
    compose="$(compose_file_for_instance "${instance}")" || return 1
    compose_files+=("${compose}")
    labels+=("${instance}")
  done

  echo ""
  echo "Will set asap_run dockerfile to ${DOCKERFILE_NAME} in:"
  for i in "${!compose_files[@]}"; do
    echo "  ${labels[$i]}"
    echo "    file: ${compose_files[$i]}"
    echo "    now:  $(current_asap_run_dockerfile_line "${compose_files[$i]}")"
  done
  echo "Then run: docker-compose build asap_run (and up -d) in each instance."
  echo ""

  if ! confirm_yes "Edit both compose files and rebuild asap_run?"; then
    echo "Skipping compose dockerfile update and asap_run rebuild."
    return 0
  fi

  for i in "${!compose_files[@]}"; do
    update_asap_run_dockerfile_in_compose "${compose_files[$i]}" "${DOCKERFILE_NAME}"
  done

  for instance in "${instances[@]}"; do
    echo "Building compose asap_run in ${instance}"
    (
      cd "${instance}"
      docker-compose build asap_run
      docker-compose up -d asap_run
    )
  done
}

ensure_dockerfile
confirm_overwrite_existing_images
ALLOW_REPLACE=0
confirm_replace_existing_docker_build

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
  update_compose_and_rebuild_asap_run
fi

if [[ "${SKIP_REGISTER:-0}" != "1" ]]; then
  echo "Registering DockerBuild for ${IMAGE_REF_MAJOR} in development DB"
  cd "${ASAP2_DIR}"
  docker-compose exec -T \
    -e "ALLOW_REPLACE=${ALLOW_REPLACE:-0}" \
    website \
    bundle exec rake docker_builds:register \
    "IMAGE_REF=${IMAGE_REF_MAJOR}" \
    "PATCH_TAG=${PATCH_TAG}"
fi

echo "Done: ${IMAGE_REF_PATCH} (major ${IMAGE_REF_MAJOR})"
