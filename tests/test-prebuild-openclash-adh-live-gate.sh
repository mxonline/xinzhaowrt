#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
gate="$root/scripts/check-openclash-adh-prebuild-live.py"
python_bin="${PYTHON_BIN:-python3}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

source_sha="0123456789abcdef0123456789abcdef01234567"
contract="$tmp/product-goal-contract.json"
evidence="$tmp/live-evidence.json"

"$python_bin" - "$contract" "$evidence" "$source_sha" <<'PY'
import json
import sys

contract_path, evidence_path, source_sha = sys.argv[1:]
markers = [
    "OPENCLASH_CLEAN_STATE",
    "OPENCLASH_CONFIG_IMPORT",
    "OPENCLASH_CONFIG_SAVE",
    "OPENCLASH_ACTIVE_CONFIG_POINTER",
    "OPENCLASH_FIRST_START",
    "OPENCLASH_RESTART",
    "OPENCLASH_CONTROLLER",
    "ZASHBOARD_RUNTIME",
    "OPENCLASH_RUNTIME_CONFIG_PARITY",
    "OPENCLASH_DNS_RUNTIME",
    "REAL_PROXY_TRAFFIC",
    "OPENCLASH_FULLY_USABLE",
    "ADGUARDHOME_FULLY_USABLE",
    "OPENCLASH_ADH_COEXISTENCE",
    "REBOOT_PERSISTENCE",
    "SYSTEM_HEALTH",
    "FINAL_ADH_DEFAULT_OFF",
]
json.dump({
    "gate": "PREBUILD_CLEAN_STATE_PRODUCT_GATE",
    "required_live_markers": markers,
    "required_build_markers": [
        "REAL_DEVICE_FULL_VALIDATION",
        "FINAL_SOURCE_FROZEN",
        "EXACT_SOURCE_BINDING",
    ],
    "source_binding": {
        "evidence_field": "final_source_sha",
        "validation_rerun_field": "validation_rerun_after_final_source_commit",
        "validation_reuse_field": "validation_reused_without_rerun_after_commit",
        "validation_reuse_must_equal": False,
        "known_runtime_defects_field": "known_runtime_defects",
        "known_runtime_defects_must_be_empty": True,
    },
    "evidence_path": "output/real-device/final-live-evidence.json",
}, open(contract_path, "w"), indent=2)
evidence = {marker: "PASS" for marker in markers}
evidence.update({
    "final_source_sha": source_sha,
    "FINAL_SOURCE_FROZEN": "PASS",
    "REAL_DEVICE_FULL_VALIDATION": "PASS",
    "EXACT_SOURCE_BINDING": "PASS",
    "validation_rerun_after_final_source_commit": True,
    "validation_reused_without_rerun_after_commit": False,
    "known_runtime_defects": [],
})
json.dump(evidence, open(evidence_path, "w"), indent=2)
PY

expect_pass() {
  local name="$1"
  shift
  "$@" > "$tmp/$name.out" 2>&1 || {
    cat "$tmp/$name.out" >&2
    echo "gate unexpectedly rejected valid evidence: $name" >&2
    exit 1
  }
  grep -Fq 'PREBUILD_CLEAN_STATE_PRODUCT_GATE=PASS' "$tmp/$name.out"
  grep -Fq 'BUILD_ALLOWED=true' "$tmp/$name.out"
}

expect_fail() {
  local name="$1"
  shift
  if "$@" > "$tmp/$name.out" 2>&1; then
    cat "$tmp/$name.out" >&2
    echo "gate accepted invalid evidence: $name" >&2
    exit 1
  fi
  grep -Fq 'PREBUILD_CLEAN_STATE_PRODUCT_GATE=FAIL' "$tmp/$name.out"
  grep -Fq 'BUILD_ALLOWED=false' "$tmp/$name.out"
}

run_gate() {
  "$python_bin" "$gate" --contract "$contract" --evidence "$evidence" --source-sha "$source_sha"
}

expect_pass valid run_gate

for marker in \
  OPENCLASH_FIRST_START \
  OPENCLASH_ACTIVE_CONFIG_POINTER \
  OPENCLASH_FULLY_USABLE \
  ADGUARDHOME_FULLY_USABLE \
  OPENCLASH_ADH_COEXISTENCE \
  REBOOT_PERSISTENCE; do
  cp "$evidence" "$tmp/$marker.json"
  "$python_bin" - "$tmp/$marker.json" "$marker" <<'PY'
import json
import sys
path, marker = sys.argv[1:]
data = json.load(open(path))
data.pop(marker, None)
json.dump(data, open(path, "w"), indent=2)
PY
  evidence="$tmp/$marker.json"
  expect_fail "missing-$marker" run_gate
  evidence="$tmp/live-evidence.json"
done

cp "$root/production/evidence/prebuild-openclash-adh-live.json" "$tmp/old-evidence.json"
evidence="$tmp/old-evidence.json"
expect_fail old-evidence run_gate
evidence="$tmp/live-evidence.json"

expect_fail source-sha-change "$python_bin" "$gate" --contract "$contract" --evidence "$evidence" --source-sha "fedcba9876543210fedcba9876543210fedcba98"

cp "$evidence" "$tmp/reused.json"
"$python_bin" - "$tmp/reused.json" <<'PY'
import json
import sys
path = sys.argv[1]
data = json.load(open(path))
data["validation_reused_without_rerun_after_commit"] = True
json.dump(data, open(path, "w"), indent=2)
PY
evidence="$tmp/reused.json"
expect_fail reused-evidence run_gate
evidence="$tmp/live-evidence.json"

grep -Fq 'check-openclash-adh-prebuild-live.py' "$root/scripts/build.sh"
grep -Fq 'PREBUILD_CLEAN_STATE_PRODUCT_GATE' "$root/.github/workflows/arthur-update-v3.yml"
[[ -f "$root/.github/workflows/arthur-prebuild-live-guard.yml" ]]

echo 'FINAL_BUILD_RULE_ENFORCED=PASS'
echo 'BUILD_WORKFLOW_FAIL_CLOSED=PASS'
