#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$ROOT/production/current-changeset.json"
WORKFLOW="${GITHUB_WORKFLOW:-LOCAL_OR_DEVELOPMENT}"

case "$WORKFLOW" in
  'Arthur Theme Candidate SDK and ImageBuilder'|\
  'Arthur Fast Candidate SDK and ImageBuilder'|\
  'Build XinZhaoWrt Arthur')
    echo "PRODUCTION_ENTRY_GATE=CHECK workflow=$WORKFLOW"
    bash "$ROOT/scripts/implementation-complete-gate.sh" "$STATE"
    echo "PRODUCTION_ENTRY_GATE=PASS workflow=$WORKFLOW"
    ;;
  *)
    echo "PRODUCTION_ENTRY_GATE=SKIP workflow=$WORKFLOW"
    ;;
esac
