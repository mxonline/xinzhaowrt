#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="$root/.github/workflows/arthur-update-v3.yml"
setup="$root/scripts/codex-setup.sh"
build="$root/scripts/build.sh"
fail() { echo "PRODUCTION_WORKFLOW_CONTRACT: FAIL -- $*" >&2; exit 1; }

# The production preflight must not run source-dependent acceptance checks
# before the build has prepared the pinned package feeds.
! grep -Fq './scripts/verify-project.sh' "$setup" || fail 'dependency setup runs source-dependent project verification too early'
! grep -Fq './scripts/verify-project.sh' "$workflow" || fail 'production workflow runs source-dependent project verification before build.sh'

source_line="$(grep -nF '"$PROJECT_ROOT/scripts/add-custom-packages.sh" "$SRC"' "$build" | cut -d: -f1 | head -n1)"
verify_line="$(grep -nF '"$PROJECT_ROOT/scripts/verify-project.sh"' "$build" | cut -d: -f1 | head -n1)"
test -n "$source_line" || fail 'build.sh does not prepare the external package feed'
test -n "$verify_line" || fail 'build.sh does not run the project verification gate'
test "$source_line" -lt "$verify_line" || fail 'project verification runs before the pinned package feed is prepared'

grep -Fq 'link_pkg "$pkg" "$IMMORTAL_LUCI/applications/$pkg"' "$root/scripts/add-custom-packages.sh" || \
  fail 'production source preparation is not wired to the ImmortalWrt LuCI applications tree'
grep -Fq 'luci-app-adguardhome' "$root/scripts/add-custom-packages.sh" || \
  fail 'production source preparation does not include luci-app-adguardhome'

echo 'PRODUCTION_WORKFLOW_CONTRACT: PASS'
