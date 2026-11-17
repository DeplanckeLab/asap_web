# shellcheck shell=bash
# Helpers shared by build_asap_run.sh (build + pin on dev) and retag_asap_run_major.sh
# (move :vX / :latest to what prod runs). Source this file; do not execute it.
#
# Model: dev and prod share one docker daemon and one Docker Hub repo, so each database
# pins the patch build its instance runs in docker_images.runtime_tag (DockerImage.runtime_ref).
# build_asap_run.sh pins dev; reference_data:steps_std_methods:sync_from_dev copies the pin
# to prod (= promotion) and rebuilds prod compose asap_run. :vX / :latest only move after
# that, and then mean "what prod runs".

confirm_yes() {
  local prompt="$1"
  local answer=""
  if [[ ! -t 0 ]]; then
    echo "Non-interactive stdin: refusing without confirmation."
    echo "Re-run with a TTY, or set FORCE=1 where supported."
    return 1
  fi
  read -r -p "${prompt} [y/N] " answer
  case "${answer}" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

# Parse <version> (8.3 / v8.3) into PATCH_TAG=v8.3, MAJOR_TAG=v8, VERSION_NUM=8.3.
# Promotion and pinning need a patch version, so a bare major is rejected when $2=patch_only.
parse_version_arg() {
  local raw="$1"
  local mode="${2:-}"
  VERSION_NUM="${raw#v}"
  if [[ "${mode}" == "patch_only" ]]; then
    if [[ ! "${VERSION_NUM}" =~ ^[0-9]+\.[0-9]+$ ]]; then
      echo "Invalid version: ${raw} (expected a patch version such as 8.3 or v8.3)"
      exit 1
    fi
  elif [[ ! "${VERSION_NUM}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    echo "Invalid version: ${raw}"
    echo "Expected forms: 8, 8.3, v8, v8.3"
    exit 1
  fi
  PATCH_TAG="v${VERSION_NUM}"
  MAJOR_TAG="v${VERSION_NUM%%.*}"
}

# Resolve compose file path for an instance (follow docker-compose.yml symlink when present).
compose_file_for_instance() {
  local instance_dir="$1"
  local compose="${instance_dir}/docker-compose.yml"
  if [[ -e "${compose}" ]]; then
    readlink -f "${compose}"
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

# Rewrite asap_run dockerfile to $2. Supports both:
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

# Point one instance's long-running compose asap_run service at a patch Dockerfile and
# rebuild it. (Runs started by Rails follow docker_images.runtime_tag, not this container.)
# Args: instance_dir dockerfile_name
rebuild_compose_asap_run() {
  local instance="$1"
  local dockerfile_name="$2"
  local compose
  compose="$(compose_file_for_instance "${instance}")" || return 1
  update_asap_run_dockerfile_in_compose "${compose}" "${dockerfile_name}"
  (
    cd "${instance}"
    docker-compose build asap_run
    docker-compose up -d asap_run
  )
}

# Register the DockerBuild for a patch ref in one instance's database; pin=1 also sets
# docker_images.runtime_tag so that instance runs it.
# Args: instance_dir image_ref_patch patch_tag allow_replace pin
register_docker_build() {
  local instance="$1"
  local image_ref="$2"
  local patch="$3"
  local allow_replace="${4:-0}"
  local pin="${5:-0}"
  echo "Registering DockerBuild ${image_ref} in ${instance} database (pin=${pin})"
  (
    cd "${instance}"
    docker-compose exec -T \
      -e "ALLOW_REPLACE=${allow_replace}" \
      -e "PIN=${pin}" \
      website \
      bundle exec rake docker_builds:register \
      "IMAGE_REF=${image_ref}" \
      "PATCH_TAG=${patch}"
  )
}

# Pinned runtime_tag of name:major in one instance's database (empty when unpinned).
# Args: instance_dir image_name major_tag
db_runtime_tag() {
  local instance="$1"
  local name="$2"
  local major="$3"
  (
    cd "${instance}"
    docker-compose exec -T website bundle exec rails runner \
      "puts \"RUNTIME_TAG=#{DockerImage.find_by(name: '${name}', tag: '${major}')&.runtime_tag}\"" 2>/dev/null
  ) | tr -d '\r' | grep -E '^RUNTIME_TAG=' | tail -n 1 | cut -d= -f2- || true
}
