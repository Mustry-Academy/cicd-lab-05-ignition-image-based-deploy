#!/bin/bash
# Shared helpers for setup.sh / trigger-scan.sh / teardown.sh.
# Sourced, not executed: . "$(dirname "$0")/lib.sh"

# Guard against direct execution.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  echo "scripts/lib.sh is meant to be sourced, not executed." >&2
  exit 1
fi

# Idempotent — only initialize once.
if [ "${_LAB_LIB_LOADED:-0}" = "1" ]; then
  return 0
fi
_LAB_LIB_LOADED=1

# Repo + scripts dir (works regardless of caller's cwd).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors. Suppress when stdout isn't a terminal or NO_COLOR is set.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; NC=''
fi

# Names of the three gateways the lab ships with. Used for iteration in
# setup.sh and validation in trigger-scan.sh.
LAB_GATEWAYS=(local dev prod)

# Map a gateway name → its host-facing URL.
gateway_url() {
  case "${1:-local}" in
    local) printf 'http://localhost:8088' ;;
    dev)   printf 'http://localhost:8089' ;;
    prod)  printf 'http://localhost:8090' ;;
    *)     return 1 ;;
  esac
}

# Map a gateway name → its docker container name (the value of
# `container_name:` in docker-compose.yaml). Used by the deploy scripts and by
# setup.sh to print log hints.
gateway_container() {
  case "${1:-local}" in
    local) printf 'lab05-ignition-local' ;;
    dev)   printf 'lab05-ignition-dev' ;;
    prod)  printf 'lab05-ignition-prod' ;;
    *)     return 1 ;;
  esac
}

# Map a gateway name → the compose service name (used by deploy-image.sh to
# recreate the right service from a new image).
gateway_service() {
  case "${1:-local}" in
    local) printf 'ignition-local' ;;
    dev)   printf 'ignition-dev' ;;
    prod)  printf 'ignition-prod' ;;
    *)     return 1 ;;
  esac
}

# Resolve the image repo base for the build/deploy scripts. Precedence:
#   1. IGNITION_IMAGE_REPO already in the environment
#   2. IGNITION_IMAGE_REPO from .env
#   3. a local-only fallback so the build scripts work before GHCR is wired up
image_repo() {
  local repo="${IGNITION_IMAGE_REPO:-}"
  [ -z "$repo" ] && repo="$(env_value IGNITION_IMAGE_REPO)"
  [ -z "$repo" ] && repo="cicd-lab-05-ignition"   # local-only default (no registry)
  printf '%s' "$repo"
}

# Read a single KEY from a .env-style file (default: <repo>/.env).
# Strips optional single/double quotes around the value.
env_value() {
  local key="$1"
  local env_file="${2:-$PROJECT_ROOT/.env}"
  [ -f "$env_file" ] || { echo ""; return; }
  local v
  v="$(grep -E "^[[:space:]]*${key}=" "$env_file" | head -n1 | cut -d= -f2-)"
  v="${v%\"}"; v="${v#\"}"
  v="${v%\'}"; v="${v#\'}"
  printf '%s' "$v"
}

# Populate IGNITION_API_KEY from .env. Precedence (first non-empty wins):
#   1. IGNITION_API_KEY already set in the environment (CI sets this)
#   2. IGNITION_API_KEY_<GATEWAY> from .env (when $1 is local|dev|prod)
#   3. IGNITION_API_KEY from .env (legacy single-key shape)
load_api_key_from_env() {
  if [ -n "${IGNITION_API_KEY:-}" ]; then
    return 0
  fi
  local gateway="${1:-}"
  if [ -n "$gateway" ]; then
    local per_gw
    case "$gateway" in
      local) per_gw="$(env_value IGNITION_API_KEY_LOCAL)" ;;
      dev)   per_gw="$(env_value IGNITION_API_KEY_DEV)" ;;
      prod)  per_gw="$(env_value IGNITION_API_KEY_PROD)" ;;
    esac
    if [ -n "${per_gw:-}" ]; then
      IGNITION_API_KEY="$per_gw"
      export IGNITION_API_KEY
      return 0
    fi
  fi
  IGNITION_API_KEY="$(env_value IGNITION_API_KEY)"
  export IGNITION_API_KEY
}

# Returns 0 if IGNITION_API_KEY is empty OR matches one of the placeholder
# values committed in .env.example (i.e. the user hasn't replaced it yet).
is_placeholder_api_key() {
  if [ -z "${IGNITION_API_KEY:-}" ]; then
    return 0
  fi
  local key
  for key in IGNITION_API_KEY IGNITION_API_KEY_LOCAL IGNITION_API_KEY_DEV IGNITION_API_KEY_PROD; do
    local example_value
    example_value="$(env_value "$key" "$PROJECT_ROOT/.env.example")"
    if [ -n "$example_value" ] && [ "$IGNITION_API_KEY" = "$example_value" ]; then
      return 0
    fi
  done
  return 1
}
