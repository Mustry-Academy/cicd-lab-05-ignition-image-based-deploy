#!/bin/bash
# One-shot setup for the lab 05 stack:
#   - sanity-checks the host (docker compose v2, curl, WSL quirks)
#   - installs the repo's git hooks (skip-worktree for the machine-local
#     Ignition config file) and a diff driver that hides volatile resource.json
#     metadata; volatile-only churn is undone with
#     scripts/clean-ignition-resource-churn.sh
#   - ensures .env is in place
#   - brings up the stack (three Ignition gateways + shared TimescaleDB)
#   - waits for ALL THREE gateways to become RUNNING
#   - triggers an initial projects + config scan against the LOCAL gateway
#     (only if its API key in .env is real, not the example placeholder).
#     Dev and prod start on the BASE image (empty gateways) by design — they get
#     replaced by the image deploy.yml builds / release.yml promotes.
#
# Re-run safely — every step is idempotent.
#
# Env knobs:
#   CI=1                            run non-interactively (no WSL prompt)
#   APPLY_WSL_PERMISSIONS=false     skip the WSL block entirely
#   NO_COLOR=1                      disable ANSI colors

set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
cd "$PROJECT_ROOT"

# ---- prerequisites --------------------------------------------------------

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo -e "${RED}Error: '$1' is required but not installed.${NC}" >&2
    exit 1
  }
}

require_cmd docker
require_cmd curl
require_cmd git
require_cmd python3

if ! docker compose version >/dev/null 2>&1; then
    echo -e "${RED}Error: Docker Compose V2 plugin is required but not installed.${NC}"
    echo ""
    echo "You appear to have the standalone 'docker-compose' (V1), which is deprecated."
    echo ""
    echo "Install the Docker Compose V2 plugin:"
    echo "  - Docker Desktop (Windows/Mac): Update to the latest version"
    echo "  - Linux/WSL: sudo apt-get update && sudo apt-get install docker-compose-plugin"
    echo "  - Or see: https://docs.docker.com/compose/install/"
    exit 1
fi

echo -e "${GREEN}Mustry Academy — Lab 05 setup${NC}"
echo "================================"
echo ""
echo "This script initializes the development environment:"
echo "  - three Ignition 8.3 gateways:"
echo "      local  http://localhost:8088   (your authoring gateway, bind-mounted from the repo)"
echo "      dev    http://localhost:8089   (runs the image deploy.yml builds on push to main)"
echo "      prod   http://localhost:8090   (runs the image release.yml promotes on tag push)"
echo "  - one TimescaleDB on localhost:5432 hosting ignition_loc / ignition_dev / ignition_prd"
echo ""

# ---- WSL compatibility ---------------------------------------------------
apply_wsl_permissions() {
    if [ "${APPLY_WSL_PERMISSIONS:-true}" != "true" ]; then
        return 0
    fi

    if ! grep -qi microsoft /proc/version 2>/dev/null; then
        return 0
    fi

    echo -e "${YELLOW}WSL detected: configuring for WSL compatibility.${NC}"

    git config core.fileMode false

    if ! grep -q "metadata" /etc/wsl.conf 2>/dev/null; then
        echo ""
        echo -e "${YELLOW}Warning: Your /etc/wsl.conf does not have metadata mount options.${NC}"
        echo -e "${YELLOW}This can cause file permission issues in VS Code.${NC}"
        echo ""
        if [ "${CI:-}" = "1" ] || [ ! -t 0 ]; then
            echo "Skipping interactive prompt (CI or non-interactive shell)."
            echo "Add the following to /etc/wsl.conf manually if you hit perms issues:"
            echo "  [automount]"
            echo "  enabled = true"
            echo '  options = "metadata,umask=022,fmask=011"'
            return 0
        fi
        read -p "Would you like to configure it now? (Y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            sudo tee /etc/wsl.conf > /dev/null <<'WSLCONF'
[automount]
enabled = true
options = "metadata,umask=022,fmask=011"
WSLCONF
            echo -e "${GREEN}wsl.conf updated. Run 'wsl --shutdown' from PowerShell and restart WSL for changes to take effect.${NC}"
        else
            echo "Skipping. You can manually add the following to /etc/wsl.conf:"
            echo ""
            echo "  [automount]"
            echo "  enabled = true"
            echo '  options = "metadata,umask=022,fmask=011"'
            echo ""
        fi
    fi
}

apply_wsl_permissions

# ---- Git hooks ------------------------------------------------------------
install_git_hooks() {
    local repo_hooks_dir
    repo_hooks_dir="$(git rev-parse --git-path hooks 2>/dev/null)" || return 0
    local source_dir="$PROJECT_ROOT/scripts/git-hooks"
    [ -d "$source_dir" ] || return 0
    mkdir -p "$repo_hooks_dir"
    for hook in post-merge post-checkout post-rewrite; do
        local target="$repo_hooks_dir/$hook"
        ln -sf "$source_dir/$hook" "$target"
    done
    [ -x "$source_dir/skip-worktree-ignition-resources" ] && \
        "$source_dir/skip-worktree-ignition-resources" || true
}

install_git_hooks

# ---- Git diff driver --------------------------------------------------------
# .gitattributes routes resource.json through this textconv normalizer so
# volatile Designer metadata (timestamps, signatures) never shows up in diffs.
configure_git_diff_drivers() {
    git config diff.ignition-resource.textconv "$PROJECT_ROOT/scripts/git-diff/normalize-ignition-resource-json.py"
}

configure_git_diff_drivers

# ---- .env -----------------------------------------------------------------
ensure_env_file() {
    if [ -f "$PROJECT_ROOT/.env" ]; then
        return 0
    fi
    if [ ! -f "$PROJECT_ROOT/.env.example" ]; then
        echo -e "${RED}Error: neither .env nor .env.example found.${NC}" >&2
        exit 1
    fi
    echo -e "${YELLOW}.env not found — copying from .env.example.${NC}"
    cp "$PROJECT_ROOT/.env.example" "$PROJECT_ROOT/.env"
    echo -e "${YELLOW}Edit .env to set gateway passwords. The IGNITION_API_KEY already${NC}"
    echo -e "${YELLOW}matches the pre-provisioned token — no gateway UI steps needed.${NC}"
    echo ""
}

ensure_env_file

# ---- Start the stack ------------------------------------------------------
existing_id="$(docker compose ps -q ignition-local 2>/dev/null || true)"
if [ -n "$existing_id" ]; then
    echo -e "${YELLOW}Stack already running — 'docker compose up -d' will be a no-op or apply changes.${NC}"
fi
echo -e "${GREEN}Starting the stack...${NC}"
docker compose up -d
echo ""
docker compose ps
echo ""

# ---- Wait for the gateways ------------------------------------------------
wait_for_gateway() {
    local gateway="$1"
    local url
    url="$(gateway_url "$gateway")"
    echo -e "${GREEN}Waiting for $gateway gateway at $url to become RUNNING...${NC}"
    local attempts=0
    local max_attempts=120  # ~4 minutes per gateway; cold start is slow
    while [ $attempts -lt $max_attempts ]; do
        local state
        state="$(curl -fsS "${url}/StatusPing" 2>/dev/null | grep -o RUNNING || true)"
        if [ "$state" = "RUNNING" ]; then
            echo ""
            echo -e "${GREEN}  $gateway gateway RUNNING${NC}"
            return 0
        fi
        attempts=$((attempts + 1))
        sleep 2
        echo -n "."
    done
    echo ""
    local container
    container="$(gateway_container "$gateway")"
    echo -e "${RED}Error: $gateway gateway did not reach RUNNING within $((max_attempts * 2))s.${NC}" >&2
    echo "  Check logs:  docker logs --tail 200 $container" >&2
    return 1
}

# Wait for each in series. Could be parallelized; sequential output is
# easier to scan and the total cold-start time is dominated by the JVM
# startup of each gateway anyway.
for gw in "${LAB_GATEWAYS[@]}"; do
    wait_for_gateway "$gw"
done

# ---- API-permission repair (first boot only) ------------------------------
# On the FIRST boot of a fresh gateway container, Ignition's auto-commissioning
# resets the read/write permissions in security-properties, which locks the
# pre-provisioned API key out: it still authenticates (bad key = 401) but every
# call gets 403. Detect that and graft the APIToken permissions back
# (scripts/fix-gateway-api-perms.sh restarts the affected gateways). The local
# gateway only hits this once (persistent volume); dev/prod hit it again on
# every image deploy — the deploy flow handles those.
repair_api_perms() {
    load_api_key_from_env local
    if is_placeholder_api_key; then
        return 0   # no key to probe with; initial_scan prints the guidance
    fi
    local needs_fix=()
    local gw url code
    for gw in "${LAB_GATEWAYS[@]}"; do
        url="$(gateway_url "$gw")"
        code="$(curl -s -o /dev/null -w '%{http_code}' -m 10 -X POST             -H "X-Ignition-API-Token: $IGNITION_API_KEY"             "$url/data/api/v1/scan/projects" || true)"
        [ "$code" = "403" ] && needs_fix+=("$gw")
    done
    [ ${#needs_fix[@]} -eq 0 ] && return 0
    echo -e "${YELLOW}First-boot commissioning reset the API permissions on: ${needs_fix[*]}${NC}"
    echo "Grafting the APIToken permissions back and restarting..."
    "$SCRIPT_DIR/fix-gateway-api-perms.sh" "${needs_fix[@]}"
}

repair_api_perms

# ---- Initial scan (local only) -------------------------------------------
# Local has projects on disk from the bind mount; dev/prod start empty by
# design (workflows will populate them).
initial_scan() {
    if [ ! -x "$SCRIPT_DIR/trigger-scan.sh" ]; then
        echo -e "${YELLOW}scripts/trigger-scan.sh missing or not executable, skipping initial scan.${NC}"
        return 0
    fi

    load_api_key_from_env local
    if is_placeholder_api_key; then
        echo -e "${YELLOW}No API key in .env yet — skipping initial scan.${NC}"
        echo "  The lab ships a pre-provisioned token; copy the IGNITION_API_KEY line"
        echo "  from .env.example into .env, then run:"
        echo "    scripts/trigger-scan.sh both --gateway local"
        return 0
    fi

    echo -e "${GREEN}Triggering initial scan on local gateway...${NC}"
    if ! "$SCRIPT_DIR/trigger-scan.sh" both --gateway local; then
        echo ""
        echo -e "${YELLOW}Initial scan failed (likely the key lacks scan permission).${NC}"
        echo "  Fix the role for the API key, then run:  scripts/trigger-scan.sh both --gateway local"
    fi
}

initial_scan

# ---- Done -----------------------------------------------------------------
# Pull the actual values from .env so the output matches reality.
ACTUAL_LOCAL_USER="$(env_value GATEWAY_ADMIN_USERNAME_LOCAL)"
ACTUAL_LOCAL_PASS="$(env_value GATEWAY_ADMIN_PASSWORD_LOCAL)"
ACTUAL_DEV_USER="$(env_value GATEWAY_ADMIN_USERNAME_DEV)"
ACTUAL_DEV_PASS="$(env_value GATEWAY_ADMIN_PASSWORD_DEV)"
ACTUAL_PROD_USER="$(env_value GATEWAY_ADMIN_USERNAME_PROD)"
ACTUAL_PROD_PASS="$(env_value GATEWAY_ADMIN_PASSWORD_PROD)"
ACTUAL_PG_USER="$(env_value POSTGRES_USER)"
ACTUAL_PG_PASS="$(env_value POSTGRES_PASSWORD)"

echo ""
echo -e "${GREEN}Setup complete!${NC}"
echo ""
printf "Gateways:\n"
printf "  %-8s  %-23s  user=%s  pass=%s\n" "local"  "http://localhost:8088"  "${ACTUAL_LOCAL_USER:-admin}"  "${ACTUAL_LOCAL_PASS:-(see .env)}"
printf "  %-8s  %-23s  user=%s  pass=%s\n" "dev"    "http://localhost:8089"  "${ACTUAL_DEV_USER:-admin}"    "${ACTUAL_DEV_PASS:-(see .env)}"
printf "  %-8s  %-23s  user=%s  pass=%s\n" "prod"   "http://localhost:8090"  "${ACTUAL_PROD_USER:-admin}"   "${ACTUAL_PROD_PASS:-(see .env)}"
echo ""
echo "TimescaleDB:"
echo "  Host: localhost  Port: 5432"
echo "  Databases: ignition_loc, ignition_dev, ignition_prd"
echo "  Username: ${ACTUAL_PG_USER:-ignition}  Password: ${ACTUAL_PG_PASS:-(see .env)}"
echo ""
if is_placeholder_api_key; then
    echo -e "${YELLOW}Next steps (LOCAL gateway only):${NC}"
    echo "  The local gateway is your file-based authoring loop. To scan it via the API,"
    echo "  copy the IGNITION_API_KEY line from .env.example into .env — it matches the"
    echo "  pre-provisioned 'cicd' token baked into services/config, so it works as-is."
    echo "  Dev and prod are NOT scanned — they're redeployed by building/promoting an"
    echo "  image (see exercises/lab.md). No API key needed for them."
    echo ""
fi
echo "Useful commands:"
echo "  docker compose ps                              # check container state"
echo "  docker logs -f lab05-ignition-local            # tail local gateway logs"
echo "  scripts/trigger-scan.sh both                   # rescan local (file-based loop)"
echo "  scripts/build-image.sh                         # build the gateway image"
echo "  scripts/deploy-image.sh dev <image>            # recreate dev from an image"
echo "  scripts/teardown.sh                            # stop the stack"
echo "  scripts/teardown.sh --volumes                  # stop and wipe persistent data"
