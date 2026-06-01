#!/usr/bin/env bash
# deploy-image.sh — the LOCAL mirror of the CI deploy step.
#
# Recreates a gateway container from a given image tag and waits for it to come
# back healthy. This is the "pull → run" half of the image-based pattern; the
# CI `deploy` job does the same thing on the self-hosted runner.
#
# How it works: docker-compose.yaml reads IGNITION_DEV_IMAGE / IGNITION_PROD_IMAGE
# to decide which image the dev/prod gateway runs. This script sets that variable
# and runs `docker compose up -d ignition-<env>`, which recreates the container
# because its image changed. No file copy, no scan — the project/config/modules
# are already inside the image.
#
# Usage:
#   scripts/deploy-image.sh dev                      # deploy <repo>:local to dev
#   scripts/deploy-image.sh dev <repo>:sha-abc1234   # deploy a specific tag
#   scripts/deploy-image.sh prod <repo>:v0.1.0       # promote a tag to prod
#
# Note: deploying to `local` is not supported — local is your bind-mounted
# authoring gateway, not an image target.

set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
cd "$PROJECT_ROOT"

ENV_NAME="${1:-}"
IMAGE="${2:-}"

case "$ENV_NAME" in
  dev|prod) ;;
  -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "ERROR: first arg must be 'dev' or 'prod' (got '${ENV_NAME:-}')" >&2; exit 2 ;;
esac

command -v docker >/dev/null || { echo -e "${RED}docker not installed${NC}" >&2; exit 1; }

# Default image: the most recent local build (<repo>:local).
[ -z "$IMAGE" ] && IMAGE="$(image_repo):local"

SERVICE="$(gateway_service "$ENV_NAME")"
CONTAINER="$(gateway_container "$ENV_NAME")"
URL="$(gateway_url "$ENV_NAME")"

# Make sure the image is actually available to the daemon. If it's a registry
# tag that isn't pulled yet, try to pull it (CI logs in first; locally you must
# already be `docker login`-ed for a private GHCR package).
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo -e "${YELLOW}Image $IMAGE not present locally — attempting docker pull...${NC}"
  docker pull "$IMAGE"
fi

echo -e "${GREEN}Deploying${NC} $IMAGE → $ENV_NAME gateway ($CONTAINER)"

# Recreate just this service from the new image. The env var override is what
# docker-compose.yaml interpolates into the service's `image:`.
if [ "$ENV_NAME" = "dev" ]; then
  IGNITION_DEV_IMAGE="$IMAGE" docker compose up -d "$SERVICE"
else
  IGNITION_PROD_IMAGE="$IMAGE" docker compose up -d "$SERVICE"
fi

echo -e "${GREEN}Waiting for $ENV_NAME gateway at $URL to become RUNNING...${NC}"
attempts=0
max_attempts=120   # ~4 min; a fresh-image boot re-commissions the gateway
while [ $attempts -lt $max_attempts ]; do
  if curl -fsS --max-time 3 "$URL/StatusPing" 2>/dev/null | grep -q RUNNING; then
    echo ""
    echo -e "${GREEN}$ENV_NAME gateway RUNNING — now serving $IMAGE${NC}"
    echo "  Verify which image it runs: docker inspect -f '{{.Config.Image}}' $CONTAINER"
    exit 0
  fi
  attempts=$((attempts + 1)); sleep 2; echo -n "."
done

echo ""
echo -e "${RED}$ENV_NAME gateway did not reach RUNNING in $((max_attempts * 2))s.${NC}" >&2
echo "  Check logs: docker logs --tail 200 $CONTAINER" >&2
exit 1
