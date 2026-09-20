#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT/scripts/check-openclash-adh-prebuild-live.py"
GUARD="$ROOT/.github/workflows/arthur-prebuild-live-guard.yml"
BUILD_WORKFLOW="$ROOT/.github/workflows/arthur-update-v3.yml"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -f "$GATE" ]] || fail 'prebuild OpenClash/AdGuardHome live gate script is missing'
[[ -f "$GUARD" ]] || fail 'cross-branch prebuild live guard workflow is missing'
[[ -f "$BUILD_WORKFLOW" ]] || fail 'Arthur Candidate workflow is missing'

for marker in   OPENCLASH_FULLY_USABLE   ADGUARDHOME_FULLY_USABLE   OPENCLASH_ADH_COEXISTENCE   OPENCLASH_CONTROLLER   ZASHBOARD_RUNTIME   OPENCLASH_RUNTIME_CONFIG_PARITY   OPENCLASH_DNS_RUNTIME   OPENCLASH_ADH_DNS_CHAIN   REAL_PROXY_TRAFFIC   ADGUARDHOME_FILTERING   ADGUARDHOME_QUERY_LOG   NO_DNS_LOOP   NO_PORT_CONFLICT   NO_OOM_OR_MANAGEMENT_PLANE_LOSS   ADH_DISABLE_LEAVES_OPENCLASH_WORKING   ADH_REENABLE_RESTORES_CHAIN   FINAL_ADH_DEFAULT_OFF; do
  grep -Fq ""$marker"" "$GATE" || fail "required machine marker missing from gate: $marker"
done

grep -Fq 'production/evidence/prebuild-openclash-adh-live.json' "$GATE" || fail 'gate must require durable prebuild live evidence'
grep -Fq 'validated_source_sha' "$GATE" || fail 'gate must bind evidence to the validated source'
grep -Fq 'source changed after live validation' "$GATE" || fail 'gate must reject source drift after live validation'

grep -Fq 'workflow_run:' "$GUARD" || fail 'guard must observe Candidate workflow runs from the default branch'
grep -Fq 'Arthur Known-Good Update v3' "$GUARD" || fail 'guard must target the production Candidate workflow'
grep -Fq 'actions: write' "$GUARD" || fail 'guard needs Actions write permission to cancel unsafe Candidate runs'
grep -Fq '/cancel' "$GUARD" || fail 'guard must cancel an unsafe Candidate run'
grep -Fq 'check-openclash-adh-prebuild-live.py' "$GUARD" || fail 'guard must execute the live evidence gate'

grep -Fq 'Enforce prebuild OpenClash + AdGuardHome live gate' "$BUILD_WORKFLOW" || fail 'Candidate workflow must run the live gate before Build'
grep -Fq 'check-openclash-adh-prebuild-live.py "$GITHUB_SHA"' "$BUILD_WORKFLOW" || fail 'Candidate workflow must bind live evidence to its exact source SHA'

echo 'PREBUILD_OPENCLASH_ADH_GATE_CONTRACT=PASS'
