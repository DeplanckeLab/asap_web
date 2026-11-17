#!/usr/bin/env bash
# After promoting a build to prod with reference_data:steps_std_methods:sync_from_dev,
# move fabdavid/asap_run:vX and :latest to the patch build prod now runs (its
# docker_images.runtime_tag) and push them, so the major tag keeps meaning "what prod runs"
# for people pulling fabdavid/asap_run:vX by hand. ASAP itself does not need this step:
# both instances run their pinned vX.Y tag.
#
# Usage:
#   ./retag_asap_run_major.sh [major]     # default v8
#
# Optional env:
#   ASAP_DIR    (default /srv/asap)  # prod instance (source of the pin)
#   IMAGE_NAME  (default fabdavid/asap_run)
#   SKIP_PUSH=1 retag locally only

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=asap_run_common.sh
source "${SCRIPT_DIR}/asap_run_common.sh"

ASAP_DIR="${ASAP_DIR:-/srv/asap}"
IMAGE_NAME="${IMAGE_NAME:-fabdavid/asap_run}"
MAJOR_TAG="v${1:-v8}"
MAJOR_TAG="v${MAJOR_TAG//v/}"
if [[ ! "${MAJOR_TAG}" =~ ^v[0-9]+$ ]]; then
  echo "Usage: $0 [major]   e.g. $0 v8"
  exit 1
fi

prod_pin="$(db_runtime_tag "${ASAP_DIR}" "${IMAGE_NAME}" "${MAJOR_TAG}")"
if [[ -z "${prod_pin}" ]]; then
  echo "Prod (${ASAP_DIR}) has no runtime_tag pin for ${IMAGE_NAME}:${MAJOR_TAG}; nothing to do."
  echo "(Promote first with RAILS_ENV=production bin/rake reference_data:steps_std_methods:sync_from_dev.)"
  exit 1
fi

IMAGE_REF_PATCH="${IMAGE_NAME}:${prod_pin}"
IMAGE_REF_MAJOR="${IMAGE_NAME}:${MAJOR_TAG}"
IMAGE_REF_LATEST="${IMAGE_NAME}:latest"

if ! docker image inspect "${IMAGE_REF_PATCH}" >/dev/null 2>&1; then
  docker pull "${IMAGE_REF_PATCH}"
fi

patch_id="$(docker image inspect --format '{{.Id}}' "${IMAGE_REF_PATCH}")"
major_id="$(docker image inspect --format '{{.Id}}' "${IMAGE_REF_MAJOR}" 2>/dev/null || echo none)"
echo "Prod runs ${IMAGE_REF_PATCH}  (${patch_id})"
echo "${IMAGE_REF_MAJOR} is currently   (${major_id})"
if [[ "${patch_id}" == "${major_id}" ]]; then
  echo "${IMAGE_REF_MAJOR} already points at ${prod_pin}."
fi

push_note=" and push them"
[[ "${SKIP_PUSH:-0}" == "1" ]] && push_note=""
if ! confirm_yes "Move ${IMAGE_REF_MAJOR} and ${IMAGE_REF_LATEST} to ${prod_pin}${push_note}?"; then
  echo "Left ${IMAGE_REF_MAJOR} / ${IMAGE_REF_LATEST} unchanged."
  exit 0
fi

docker tag "${IMAGE_REF_PATCH}" "${IMAGE_REF_MAJOR}"
docker tag "${IMAGE_REF_PATCH}" "${IMAGE_REF_LATEST}"
if [[ "${SKIP_PUSH:-0}" != "1" ]]; then
  docker push "${IMAGE_REF_MAJOR}"
  docker push "${IMAGE_REF_LATEST}"
fi
echo "Done: ${IMAGE_REF_MAJOR} and ${IMAGE_REF_LATEST} -> ${prod_pin}"
