#!/bin/bash
# Stop and remove the lab stack.
#
# Usage:
#   scripts/teardown.sh              # docker compose down (keeps volumes)
#   scripts/teardown.sh --volumes    # also wipes named volumes — DATA LOSS
#   scripts/teardown.sh --help

set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
cd "$PROJECT_ROOT"

REMOVE_VOLUMES=false
for arg in "$@"; do
  case "$arg" in
    -v|--volumes) REMOVE_VOLUMES=true ;;
    -h|--help)
      sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      echo "Try: scripts/teardown.sh --help" >&2
      exit 2
      ;;
  esac
done

if [ "$REMOVE_VOLUMES" = "true" ]; then
  echo -e "${YELLOW}This will wipe named volumes (gateway internal DB, TimescaleDB data).${NC}"
  if [ -t 0 ] && [ "${CI:-}" != "1" ]; then
    read -p "Continue? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      echo "Aborted."
      exit 0
    fi
  fi
  echo -e "${GREEN}Stopping stack and removing volumes...${NC}"
  docker compose down -v
else
  echo -e "${GREEN}Stopping stack (volumes retained)...${NC}"
  docker compose down
fi

echo -e "${GREEN}Done.${NC}"
