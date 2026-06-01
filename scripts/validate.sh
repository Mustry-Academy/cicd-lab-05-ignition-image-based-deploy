#!/bin/bash
# validate.sh — local mirror of .github/workflows/ci.yml.
#
# Run this before opening a PR to catch the cheap stuff the CI workflow checks,
# without waiting for a runner:
#   1. Every *.json under projects/ and services/ parses.
#   2. .dockerignore excludes the lab/secret paths it should.
#   3. hadolint passes on the Dockerfile (only if hadolint is installed).
#   4. actionlint passes on .github/workflows/ (only if actionlint is installed).
#
# Exits non-zero if any check fails. No Ignition needed; Docker only if you want
# the optional build smoke test (CI always does it — see ci.yml).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
cd "$PROJECT_ROOT"

rc=0

# 1. JSON validity sweep -------------------------------------------------------
echo "→ JSON validity sweep (projects/, services/)"
json_fail=0
while IFS= read -r f; do
  if ! python3 -m json.tool "$f" > /dev/null 2>&1; then
    echo -e "  ${RED}invalid JSON:${NC} $f"
    json_fail=1
  fi
done < <(find projects services -type f -name '*.json' 2>/dev/null)
if [ "$json_fail" -eq 0 ]; then
  echo -e "  ${GREEN}ok${NC} — all JSON parses"
else
  rc=1
fi

# 2. .dockerignore sanity ------------------------------------------------------
# The build context must not carry secrets or lab tooling into the image. We
# don't reimplement Docker's matcher — we just confirm the must-exclude paths
# are present as patterns.
echo "→ .dockerignore excludes secrets + lab tooling"
if [ -f .dockerignore ]; then
  di_fail=0
  for must in ".env" ".git/" "scripts/" "docs/" "exercises/"; do
    if ! grep -qxF "$must" .dockerignore; then
      echo -e "  ${RED}missing pattern:${NC} $must"
      di_fail=1
    fi
  done
  if [ "$di_fail" -eq 0 ]; then
    echo -e "  ${GREEN}ok${NC} — required exclusions present"
  else
    rc=1
  fi
else
  echo -e "  ${RED}no .dockerignore${NC} — the build context would carry everything"
  rc=1
fi

# 3. hadolint on the Dockerfile (optional) -------------------------------------
echo "→ hadolint (Dockerfile)"
if command -v hadolint > /dev/null 2>&1; then
  if hadolint Dockerfile; then
    echo -e "  ${GREEN}ok${NC}"
  else
    rc=1
  fi
else
  echo -e "  ${YELLOW}skipped${NC} — hadolint not installed (CI runs it; see https://github.com/hadolint/hadolint)"
fi

# 4. actionlint (optional) -----------------------------------------------------
echo "→ actionlint (.github/workflows/)"
if command -v actionlint > /dev/null 2>&1; then
  if actionlint -color; then
    echo -e "  ${GREEN}ok${NC}"
  else
    rc=1
  fi
else
  echo -e "  ${YELLOW}skipped${NC} — actionlint not installed (CI runs it; install from https://github.com/rhysd/actionlint to check locally)"
fi

echo ""
if [ "$rc" -eq 0 ]; then
  echo -e "${GREEN}validate.sh: all checks passed${NC}"
else
  echo -e "${RED}validate.sh: one or more checks failed${NC}"
fi
exit "$rc"
