#!/usr/bin/env bash
set -euo pipefail

root="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
workflow="$root/.github/workflows/build.yml"

line_of() {
  local pattern="$1"
  grep -nF "$pattern" "$workflow" | head -n1 | cut -d: -f1
}

feed_line="$(line_of '      - name: Feed Check')"
preflight_line="$(line_of '      - name: Preflight project validation')"
[[ -n "$feed_line" && -n "$preflight_line" ]] || {
  echo 'FAIL: build workflow must contain Feed Check and Preflight project validation steps' >&2
  exit 1
}
(( feed_line < preflight_line )) || {
  echo 'FAIL: source materialization must precede source-dependent project preflight' >&2
  exit 1
}

awk -v start="$preflight_line" '
  NR >= start && NR <= start + 12 { print }
' "$workflow" | grep -Fq 'ADGUARD_MANAGER_PACKAGE_ROOT: ${{ github.workspace }}/work/feed-check/immortalwrt/package/feeds/xinzhao/luci-app-adguardhome' || {
  echo 'FAIL: project preflight must point the AdGuard manager contract at the materialized Feed Check source' >&2
  exit 1
}

echo 'PASS: build preflight runs after source materialization with the pinned AdGuard feed root'
