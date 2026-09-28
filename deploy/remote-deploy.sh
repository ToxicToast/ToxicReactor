#!/usr/bin/env bash
# Runs ON the VPS, invoked over SSH by .github/workflows/deploy.yml.
# Can also be run by hand: IMAGE=ghcr.io/owner/repo/api:sha-abc1234 ./remote-deploy.sh
set -euo pipefail

STACK_DIR="${STACK_DIR:-/opt/toxicreactor}"
IMAGE="${IMAGE:?IMAGE is required, e.g. ghcr.io/owner/repo/api:sha-abc1234}"
LIVE_IMAGE_FILE="${STACK_DIR}/.live-image"

cd "$STACK_DIR"

# The tag that is live right now, before we touch anything. Empty on first deploy.
current_image="$(docker inspect --format '{{.Config.Image}}' "$(docker compose ps -q api 2>/dev/null)" 2>/dev/null || true)"

log() { printf '==> %s\n' "$*"; }

# Called when `docker compose up --wait` reports the new container as unhealthy
# or failing to start. $1 = the image tag that failed, $2 = the previously live
# image tag (empty string if this was the first deploy).
#
# TODO(you): decide what should happen here. See deploy/README.md for the
# trade-offs between auto-rollback and failing loud.
handle_failed_deploy() {
  local failed_image="$1"
  local previous_image="$2"

  echo "TODO: implement failure policy for $failed_image (previous: ${previous_image:-none})" >&2
  return 1
}

log "Pulling $IMAGE"
IMAGE="$IMAGE" docker compose pull api

log "Starting new container and waiting for health"
if ! IMAGE="$IMAGE" docker compose up -d --wait --wait-timeout 120 api; then
  log "Deploy failed - container did not become healthy"
  docker compose logs --tail 100 api || true
  handle_failed_deploy "$IMAGE" "$current_image"
  exit 1
fi

printf '%s\n' "$IMAGE" >"$LIVE_IMAGE_FILE"

log "Healthy. Pruning dangling images"
docker image prune -f >/dev/null

log "Deployed $IMAGE"
docker compose ps api
