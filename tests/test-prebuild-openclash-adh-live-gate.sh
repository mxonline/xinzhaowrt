#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT/scripts/check-openclash-adh-prebuild-live.py"
GUARD="$ROOT/.github/workflows/arthur-prebuild-live-guard.yml"
BUILD_WORKFLOW="$ROOT/.github/workflows/arthur-update-v3.yml"
REPAIR_WORKFLOW="$ROOT/.github/workflows/arthur-openclash-adh-live-repair.yml"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -f "$GATE" ]] || fail 'prebuild OpenClash/AdGuardHome live gate script is missing'
[[ -f "$GUARD" ]] || fail 'cross-branch prebuild live guard workflow is missing'
[[ -f "$BUILD_WORKFLOW" ]] || fail 'Arthur Candidate workflow is missing'

for marker in OPENCLASH_FULLY_USABLE ADGUARDHOME_FULLY_USABLE OPENCLASH_ADH_COEXISTENCE OPENCLASH_CONTROLLER ZASHBOARD_RUNTIME OPENCLASH_RUNTIME_CONFIG_PARITY OPENCLASH_DNS_RUNTIME OPENCLASH_ADH_DNS_CHAIN REAL_PROXY_TRAFFIC ADGUARDHOME_FILTERING ADGUARDHOME_QUERY_LOG NO_DNS_LOOP NO_PORT_CONFLICT NO_OOM_OR_MANAGEMENT_PLANE_LOSS ADH_DISABLE_LEAVES_OPENCLASH_WORKING ADH_REENABLE_RESTORES_CHAIN FINAL_ADH_DEFAULT_OFF; do
  grep -Fq "$marker" "$REPAIR_WORKFLOW" || fail "required live evidence marker missing from repair contract: $marker"
  case "$marker" in
    OPENCLASH_FULLY_USABLE) validation='evidence.get("openclash_fully_usable") == "PASS"' ;;
    ADGUARDHOME_FULLY_USABLE) validation='evidence.get("adguardhome_fully_usable") == "PASS"' ;;
    OPENCLASH_ADH_COEXISTENCE) validation='evidence.get("openclash_adh_coexistence") == "PASS"' ;;
    OPENCLASH_CONTROLLER) validation='controller.get(key) == 200' ;;
    ZASHBOARD_RUNTIME) validation='fake.get("zashboard_http") == 200' ;;
    OPENCLASH_RUNTIME_CONFIG_PARITY) validation='source_content_matches_validated_source_commit' ;;
    OPENCLASH_DNS_RUNTIME) validation='fake-ip source/runtime parity must be true' ;;
    OPENCLASH_ADH_DNS_CHAIN) validation='dns_chain.get("on") == "dnsmasq:53 -> AdGuardHome:1745 -> OpenClash:7874"' ;;
    REAL_PROXY_TRAFFIC) validation='proxy_http.get("google_generate_204") == 204' ;;
    ADGUARDHOME_FILTERING) validation='adh.get("filter_blocked_ipv4") == "0.0.0.0"' ;;
    ADGUARDHOME_QUERY_LOG) validation='adh.get("query_log_recorded") is True' ;;
    NO_DNS_LOOP) validation='safety.get("no_dns_loop") is True' ;;
    NO_PORT_CONFLICT) validation='safety.get("no_port_conflict") is True' ;;
    NO_OOM_OR_MANAGEMENT_PLANE_LOSS) validation='safety.get("no_oom") is True' ;;
    ADH_DISABLE_LEAVES_OPENCLASH_WORKING) validation='lifecycle.get("openclash_pid_remained_stable") is True' ;;
    ADH_REENABLE_RESTORES_CHAIN) validation='lifecycle.get("sequence") == "OFF -> ON -> OFF -> ON -> OFF"' ;;
    FINAL_ADH_DEFAULT_OFF) validation='final_state.get("adguardhome") == "OFF"' ;;
  esac
  grep -Fq "$validation" "$GATE" || fail "prebuild gate is missing evidence validation for $marker"
done

grep -Fq 'production/evidence/prebuild-openclash-adh-live.json' "$GATE" || fail 'gate must require durable prebuild live evidence'
grep -Fq 'validated_source_sha' "$GATE" || fail 'gate must bind evidence to the validated source'
grep -Fq 'source changed after live validation' "$GATE" || fail 'gate must reject source drift after live validation'
grep -Fq 'production/operator-intent.json' "$GATE" || fail 'gate must allow only the post-freeze operator source pointer metadata'
grep -Fq 'active_source_sha' "$GATE" || fail 'gate must bind operator intent to the evidence-validated source SHA'
grep -Fq 'accepted_source_sha' "$GATE" || fail 'gate must bind accepted machine evidence to the validated source SHA'
grep -Fq 'live_repair_scope' "$GATE" || fail 'gate must verify the live device write scope has been closed'
grep -Fq 'scripts/stage-openclash-core.py' "$GATE" || fail 'runtime drift gate must track the Stable OpenClash Core staging helper'
grep -Fq 'scripts/fetch-openclash-core.sh' "$GATE" || fail 'runtime drift gate must track the Stable OpenClash Core fetch path'
! grep -Fq 'scripts/stage-openclash-core.sh' "$GATE" || fail 'runtime drift gate must not track an unused current-main staging helper'

grep -Fq 'STABLE_PRODUCT_GOAL_PLUS_READ_ONLY_LIVE_SNAPSHOT' "$GATE" || fail 'gate must support explicit Stable inheritance plus a fresh read-only live snapshot'
grep -Fq '0eeae67f74db77a6401b0205d74e6518b899a3e4' "$GATE" || fail 'Stable product evidence must bind the exact verified v0.1.5 source'
grep -Fq 'b4448e62ab1e767f9a60221b0600c60c355baf56' "$GATE" || fail 'v0.1.6 evidence must bind the frozen firmware source, not a control commit'
grep -Fq 'semantic_protected_payload_unchanged' "$GATE" || fail 'gate must recompute Stable-to-frozen protected payload parity'
grep -Fq 'CURRENT_READ_ONLY_SNAPSHOT_AND_SOURCE_PARITY' "$GATE" || fail 'current markers must have a live snapshot evidence basis'
grep -Fq 'EXACT_STABLE_BASELINE_PLUS_PRIOR_FULL_PREBUILD_BEHAVIORAL_EVIDENCE' "$GATE" || fail 'inherited behavioral markers must identify both the exact Stable baseline and prior full test evidence'
grep -Fq 'PREBUILD_VALIDATION_SHA' "$ROOT/scripts/build.sh" || fail 'build entrypoint must validate the evidence commit independently from the firmware source'
grep -Fq 'prior_adh.get("filter_blocked_ipv4") == "0.0.0.0"' "$GATE" || fail 'inherited ADH filtering marker must be backed by prior machine behavior evidence'
grep -Fq 'prior_adh.get("query_log_recorded") is True' "$GATE" || fail 'inherited ADH query marker must be backed by prior machine behavior evidence'

BINDER="$ROOT/scripts/bind-prebuild-openclash-adh-evidence.py"
INSPECT="$ROOT/.github/workflows/arthur-openclash-adh-direct-inspect.yml"
[[ -f "$BINDER" ]] || fail 'machine evidence binder is missing'
grep -Fq 'actions/artifacts/' "$BINDER" || fail 'binder must resolve immutable GitHub Actions artifact evidence'
grep -Fq 'archive_sha != digest' "$BINDER" || fail 'binder must verify the snapshot artifact digest'
grep -Fq 'Arthur-OpenClash-ADH-ReadOnly-' "$INSPECT" || fail 'read-only Arthur inspection must upload a fresh snapshot artifact'
grep -Fq 'management_http_status' "$INSPECT" || fail 'read-only snapshot must record LuCI management health'
grep -Fq '$luciHttp = [int]$buildResponse.StatusCode' "$INSPECT" || fail 'management HTTP evidence must reuse the successful public build-info response'
grep -Fq 'PROXY_HTTP=204' "$INSPECT" || fail 'read-only snapshot must prove live OpenClash proxy traffic'
grep -Fq 'mixed-port|redir-port|tproxy-port' "$INSPECT" || fail 'read-only snapshot must capture runtime proxy settings for source parity'
grep -Fq 'LIVE_READ_ONLY_SNAPSHOT=PASS' "$INSPECT" || fail 'read-only snapshot production must report its explicit marker'

grep -Fq 'workflow_run:' "$GUARD" || fail 'guard must observe Candidate workflow runs from the default branch'
grep -Fq 'Arthur Known-Good Update v3' "$GUARD" || fail 'guard must target the production Candidate workflow'
grep -Fq 'actions: write' "$GUARD" || fail 'guard needs Actions write permission to cancel unsafe Candidate runs'
grep -Fq '/cancel' "$GUARD" || fail 'guard must cancel an unsafe Candidate run'
grep -Fq 'check-openclash-adh-prebuild-live.py' "$GUARD" || fail 'guard must execute the live evidence gate'

grep -Fq 'Enforce prebuild OpenClash + AdGuardHome live gate' "$BUILD_WORKFLOW" || fail 'Candidate workflow must run the live gate before Build'
grep -Fq 'check-openclash-adh-prebuild-live.py "$GITHUB_SHA"' "$BUILD_WORKFLOW" || fail 'Candidate workflow must bind live evidence to its exact source SHA'

echo 'PREBUILD_OPENCLASH_ADH_GATE_CONTRACT=PASS'
