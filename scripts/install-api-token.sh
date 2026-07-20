#!/usr/bin/env bash
# install-api-token.sh — install a gateway's scan-API token into its RUNNING
# container, derived from the key in .env.
#
# Why this exists: test/production run images and keep NO host config tree —
# every deploy recreates the container, so anything not in the image is gone
# afterwards. The API token must NOT be in the image (a published image with
# your token baked in hands your gateway's auth config to anyone who can pull
# it, and the image is shared test→production while keys are per-gateway). So
# after each (re)create, this script puts the token back:
#
#   1. derives the hash-only api-token resource from IGNITION_API_KEY_<GW>
#      in .env (the gateway stores only the SHA-256 hash of the secret)
#   2. docker-cp's it into the container's config tree
#   3. grafts the APIToken permissions into security-properties and restarts
#      the gateway once so it loads both (fix-gateway-api-perms.sh — the
#      restart is needed anyway: token resources are only read at boot)
#
# setup.sh runs this for test/production after first boot, and deploy-image.sh
# runs it after every image deploy — so a freshly deployed gateway is always
# scannable with the key in .env. Local never needs it: its token sits in the
# bind-mounted services/config (written by scripts/generate-api-keys.sh).
#
# Usage:
#   scripts/install-api-token.sh test
#   scripts/install-api-token.sh production

set -euo pipefail

# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

command -v python3 >/dev/null || { echo -e "${RED}python3 is required${NC}" >&2; exit 1; }

GW="${1:-}"
case "$GW" in
  test|production) ;;
  -h|--help) sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "Usage: $0 <test|production>" >&2; exit 2 ;;
esac

CONTAINER="$(gateway_container "$GW")"
KEY="$(api_key_for "$GW")"
if [ -z "$KEY" ]; then
  echo -e "${RED}No IGNITION_API_KEY_$(echo "$GW" | tr '[:lower:]' '[:upper:]') in .env — run scripts/generate-api-keys.sh first.${NC}" >&2
  exit 1
fi
if ! docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null | grep -q running; then
  echo -e "${RED}Container $CONTAINER is not running.${NC}" >&2
  exit 1
fi

TOKEN_DIR_IN_CONTAINER=/usr/local/bin/ignition/data/config/resources/core/ignition/api-token

# Build the resource files in a temp dir from the key.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
python3 - "$KEY" "$TMP" <<'PYEOF'
import base64, hashlib, json, os, sys, time, uuid

key, out = sys.argv[1], sys.argv[2]
name, secret_b64 = key.split(":", 1)
raw = base64.urlsafe_b64decode(secret_b64 + "=" * (-len(secret_b64) % 4))
thash = base64.urlsafe_b64encode(hashlib.sha256(raw).digest()).rstrip(b"=").decode()

api_children = [{"children": [], "name": n} for n in ("Access", "Read", "Write")]
config = {
    "profile": {
        "secureChannelRequired": False,
        "securityLevels": [{
            "children": [
                {"children": [{"children": [], "name": "Administrator"}],
                 "name": "Roles"},
                {"children": api_children, "name": "APIToken"},
            ],
            "description": "Represents a user who has been authenticated by the system.",
            "name": "Authenticated",
        }],
        "timestamp": int(time.time() * 1000),
        "type": "basic-token",
    },
    "settings": {"tokenHash": thash},
}
resource = {
    "scope": "A", "description": "", "version": 1,
    "restricted": False, "overridable": True,
    "files": ["config.json"],
    "attributes": {"uuid": str(uuid.uuid4()), "enabled": True},
}
res_dir = os.path.join(out, name)
os.makedirs(res_dir)
for fname, data in (("config.json", config), ("resource.json", resource)):
    with open(os.path.join(res_dir, fname), "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
PYEOF
TOKEN_NAME="${KEY%%:*}"

echo -e "${GREEN}[$GW]${NC} installing api-token '$TOKEN_NAME' into $CONTAINER..."
# Both a built image (bakes services/config) and a commissioned base image
# have config/resources/core on disk; only the api-token dir may be missing.
# Run the mutations as root and chown to the gateway user afterwards:
# docker cp writes root-owned files, which the gateway user (2003) could
# otherwise neither replace on a re-install nor rewrite itself.
docker exec -u root "$CONTAINER" mkdir -p "$TOKEN_DIR_IN_CONTAINER"
docker exec -u root "$CONTAINER" rm -rf "$TOKEN_DIR_IN_CONTAINER/$TOKEN_NAME"
docker cp "$TMP/$TOKEN_NAME" "$CONTAINER:$TOKEN_DIR_IN_CONTAINER/$TOKEN_NAME"
docker exec -u root "$CONTAINER" chown -R 2003:0 "$TOKEN_DIR_IN_CONTAINER"

# Graft the APIToken permissions into security-properties (commissioning
# resets them on every fresh container) and restart so the gateway loads
# both the token and the permissions.
"$SCRIPT_DIR/fix-gateway-api-perms.sh" "$GW"
