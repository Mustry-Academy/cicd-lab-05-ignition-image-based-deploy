#!/usr/bin/env bash
# build-image.sh — the LOCAL mirror of the CI build step.
#
# Builds the gateway image from the Dockerfile, baking in projects/, config,
# modules.json, and third-party-modules. Tags it two ways, exactly like CI:
#   <repo>:sha-<short>   immutable, traceable to the commit
#   <repo>:local         a moving "latest local build" pointer
#
# This is the same `docker build` that .github/workflows/deploy.yml runs on a
# GitHub-hosted runner — running it here lets you inspect the image, run it, and
# deploy it without waiting for CI.
#
# Usage:
#   scripts/build-image.sh                 # build, tag :sha-<short> and :local
#   scripts/build-image.sh --tag dev       # also tag :dev
#   IGNITION_IMAGE_REPO=ghcr.io/me/x scripts/build-image.sh
#
# The repo base comes from IGNITION_IMAGE_REPO (env or .env); without it, images
# are tagged under a local-only name (cicd-lab-05-ignition) that never pushes.

set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
cd "$PROJECT_ROOT"

EXTRA_TAG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --tag) [ $# -ge 2 ] || { echo "ERROR: --tag needs a value" >&2; exit 2; }
           EXTRA_TAG="$2"; shift 2 ;;
    --tag=*) EXTRA_TAG="${1#*=}"; shift ;;
    -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v docker >/dev/null || { echo -e "${RED}docker not installed${NC}" >&2; exit 1; }

REPO="$(image_repo)"
SHA="$(git rev-parse --short HEAD 2>/dev/null || echo nogit)"
SOURCE_URL="$(git remote get-url origin 2>/dev/null || echo 'local')"

TAGS=(-t "${REPO}:sha-${SHA}" -t "${REPO}:local")
[ -n "$EXTRA_TAG" ] && TAGS+=(-t "${REPO}:${EXTRA_TAG}")

echo -e "${GREEN}Building gateway image${NC}"
echo "  repo:    ${REPO}"
echo "  git sha: ${SHA}"
echo "  tags:    ${REPO}:sha-${SHA}, ${REPO}:local${EXTRA_TAG:+, ${REPO}:${EXTRA_TAG}}"
echo ""

docker build \
  --build-arg GIT_SHA="${SHA}" \
  --build-arg IMAGE_SOURCE="${SOURCE_URL}" \
  "${TAGS[@]}" \
  .

echo ""
echo -e "${GREEN}Built.${NC} Inspect the baked layers with:"
echo "  docker history ${REPO}:sha-${SHA}"
echo ""
echo "Run it stand-alone (no bind mounts — proves the image is self-contained):"
echo "  docker run --rm --user root -p 9088:8088 \\"
echo "    -e ACCEPT_IGNITION_EULA=Y -e IGNITION_EDITION=standard \\"
echo "    -e GATEWAY_ADMIN_USERNAME=admin -e GATEWAY_ADMIN_PASSWORD=password \\"
echo "    ${REPO}:sha-${SHA} -n demo -- -Dignition.allowunsignedmodules=true"
echo "  # then open http://localhost:9088"
echo ""
echo "Or deploy it to the dev gateway:"
echo "  scripts/deploy-image.sh dev ${REPO}:sha-${SHA}"
