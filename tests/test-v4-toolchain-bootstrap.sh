#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOTSTRAP="$ROOT/scripts/v4-toolchain-bootstrap.sh"
WORKFLOW="$ROOT/.github/workflows/arthur-toolchain-bootstrap-v4.yml"

[[ -x "$BOOTSTRAP" ]] || {
  echo "FAIL: missing executable scripts/v4-toolchain-bootstrap.sh" >&2
  exit 1
}

plan="$("$BOOTSTRAP" --plan)"

grep -qx 'MODE=PLAN' <<<"$plan"
grep -qx 'KNOWN_GOOD_TAG=v0.1.0' <<<"$plan"
grep -qx 'UPSTREAM_COMMIT=27e26e324bee0b0c2a4eb58e2e9121fea5d43194' <<<"$plan"
grep -qx 'TARGET=qualcommax/ipq60xx' <<<"$plan"
grep -qx 'PROFILE=jdcloud_re-ss-01' <<<"$plan"
grep -qx 'CONFIG_SDK=y' <<<"$plan"
grep -qx 'CONFIG_IB=y' <<<"$plan"
grep -qx 'CONFIG_IB_STANDALONE=y' <<<"$plan"

# Bootstrap must fail closed if the Known-Good record is not verified.
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
python3 - "$ROOT/production/known-good.json" "$tmp" <<'PY'
import json, sys
src, dst = sys.argv[1:]
obj = json.load(open(src, encoding='utf-8'))
obj['verified'] = False
obj['status'] = 'candidate'
json.dump(obj, open(dst, 'w', encoding='utf-8'), indent=2)
PY

if KNOWN_GOOD_JSON="$tmp" "$BOOTSTRAP" --plan >/dev/null 2>&1; then
  echo 'FAIL: bootstrap accepted an unverified Known-Good record' >&2
  exit 1
fi

[[ -f "$WORKFLOW" ]] || {
  echo 'FAIL: missing arthur-toolchain-bootstrap-v4.yml' >&2
  exit 1
}
grep -q 'workflow_dispatch:' "$WORKFLOW"
grep -q 'v4-toolchain-bootstrap.sh --plan' "$WORKFLOW"
grep -q 'v4-toolchain-bootstrap.sh --execute' "$WORKFLOW"
grep -q 'actions/upload-artifact@v4' "$WORKFLOW"
if grep -Eq '^[[:space:]]+push:' "$WORKFLOW"; then
  echo 'FAIL: v4 toolchain bootstrap must not auto-run on push' >&2
  exit 1
fi

echo 'PASS: v4 toolchain bootstrap planning and workflow gates are correct.'
