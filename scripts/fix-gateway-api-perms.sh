#!/usr/bin/env bash
# fix-gateway-api-perms.sh — restore the APIToken permissions that Ignition's
# first-boot auto-commissioning wipes from core security-properties.
#
# Why this exists: every gateway carries a generated api-token (`cicd`,
# provisioned by scripts/generate-api-keys.sh / install-api-token.sh — never
# committed, never baked into an image). But when a FRESH container boots
# (every image deploy recreates test/production), the gateway's
# auto-commissioning (driven by GATEWAY_ADMIN_USERNAME/PASSWORD) RESETS
# readPermissions/writePermissions in security-properties to
# Roles/Administrator only — which an API token can never hold. Result: the
# key authenticates (401 for a bad key) but every call is Forbidden (403).
# This script grafts the APIToken permission entries back into the
# container's live security-properties (keeping whatever systemAuthProfile
# commissioning chose), restarts the gateway, and the key works.
#
# The LOCAL gateway only ever needs this once (its data volume persists, so
# commissioning runs a single time). Test/production need it after each image
# deploy — install-api-token.sh (called by deploy-image.sh) runs it for you.
#
# Usage:
#   scripts/fix-gateway-api-perms.sh test
#   scripts/fix-gateway-api-perms.sh production
#   scripts/fix-gateway-api-perms.sh local test production

set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

command -v python3 >/dev/null || { echo -e "${RED}python3 is required${NC}" >&2; exit 1; }
[ $# -ge 1 ] || { echo "Usage: $0 <local|test|production> [more gateways...]" >&2; exit 2; }

SECPROPS_PATH=/usr/local/bin/ignition/data/config/resources/core/ignition/security-properties/config.json

graft() {
  # Adds the APIToken entries to access/read/write/createProject permissions
  # of the JSON file at $1, leaving systemAuthProfile and all other fields as
  # the gateway wrote them.
  python3 - "$1" <<'PYEOF'
import json, sys
path = sys.argv[1]
d = json.load(open(path))

def lvl(*children):
    return [{
        "children": list(children),
        "description": "Represents a user who has been authenticated by the system.",
        "name": "Authenticated",
    }]

roles_admin = {
    "children": [{
        "children": [],
        "description": "System generated security level representing read and write privileges to Gateway configuration",
        "name": "Administrator",
    }],
    "description": "Represents the roles that a user has.",
    "name": "Roles",
}

def api(*names):
    return {"children": [{"children": [], "name": n} for n in names], "name": "APIToken"}

d["accessPermissions"] = {"securityLevels": lvl(api("Access")), "type": "AnyOf"}
d["createProjectPermissions"] = {"securityLevels": lvl(roles_admin, api("Write")), "type": "AnyOf"}
d["readPermissions"] = {"securityLevels": lvl(roles_admin, api("Read")), "type": "AnyOf"}
d["writePermissions"] = {"securityLevels": lvl(roles_admin, api("Write")), "type": "AnyOf"}

json.dump(d, open(path, "w"), indent=2, sort_keys=True)
open(path, "a").write("\n")
PYEOF
}

wait_running() {
  local url="$1"
  for _ in $(seq 1 60); do
    if curl -fsS -m 3 "$url/StatusPing" 2>/dev/null | grep -q RUNNING; then
      return 0
    fi
    sleep 5
  done
  return 1
}

for gw in "$@"; do
  container="$(gateway_container "$gw")" || { echo "ERROR: unknown gateway: $gw" >&2; exit 2; }
  url="$(gateway_url "$gw")"
  echo -e "${GREEN}[$gw]${NC} grafting APIToken permissions into $container..."

  tmp="$(mktemp)"
  docker cp "$container:$SECPROPS_PATH" "$tmp"
  graft "$tmp"
  docker cp "$tmp" "$container:$SECPROPS_PATH"
  rm -f "$tmp"

  echo -e "${GREEN}[$gw]${NC} restarting $container (the gateway only reads this at boot)..."
  docker restart "$container" >/dev/null
  if wait_running "$url"; then
    echo -e "${GREEN}[$gw]${NC} gateway RUNNING — verify with: scripts/trigger-scan.sh config --gateway $gw"
  else
    echo -e "${YELLOW}[$gw]${NC} gateway not RUNNING yet; check: docker logs -f $container"
  fi
done
