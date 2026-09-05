#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for file in \
  scripts/build-fingerprint.sh \
  scripts/source-impact-gate.sh \
  scripts/resolve-candidate-dedup.sh \
  scripts/ci-controller-v3.ps1; do
  [[ -s "$ROOT/$file" ]] || { echo "FAIL: missing $file" >&2; exit 1; }
done

grep -Fq 'WATCH_EXISTING_RUN' "$ROOT/scripts/resolve-candidate-dedup.sh"
grep -Fq 'REUSE_ARTIFACT' "$ROOT/scripts/resolve-candidate-dedup.sh"
grep -Fq 'REPAIR_FAILED_RUN' "$ROOT/scripts/resolve-candidate-dedup.sh"
grep -Fq 'NO_NEW_CANDIDATE' "$ROOT/scripts/resolve-candidate-dedup.sh"
grep -Fq 'NEW_CANDIDATE' "$ROOT/scripts/resolve-candidate-dedup.sh"
grep -Fq 'resolve-candidate-dedup.sh' "$ROOT/.github/workflows/arthur-update-v3-auto.yml"
grep -Fq 'V3_AUTO_TRIGGER=WATCH_EXISTING_RUN' "$ROOT/.github/workflows/arthur-update-v3-auto.yml"
grep -Fq 'V3_AUTO_TRIGGER=REUSE_ARTIFACT' "$ROOT/.github/workflows/arthur-update-v3-auto.yml"
grep -Fq 'V3_AUTO_TRIGGER=REPAIR_FAILED_RUN' "$ROOT/.github/workflows/arthur-update-v3-auto.yml"
grep -Fq 'V3_AUTO_TRIGGER=NO_NEW_CANDIDATE' "$ROOT/.github/workflows/arthur-update-v3-auto.yml"

scope="$(printf '%s\n' \
  scripts/build-fingerprint.sh \
  scripts/source-impact-gate.sh \
  scripts/resolve-candidate-dedup.sh \
  tests/test-build-dedup-contract.sh | bash "$ROOT/scripts/classify-build-scope.sh")"
[[ "$scope" == FAST_GATE ]] || { echo "FAIL: dedup control plane classified as $scope" >&2; exit 1; }

state_scope="$(printf '%s\n' \
  production/operator-intent.json \
  production/resume-state.json \
  production/firmware-events.jsonl | bash "$ROOT/scripts/classify-build-scope.sh")"
[[ "$state_scope" == FAST_GATE ]] || { echo "FAIL: pure release-state files classified as $state_scope; they must not trigger a firmware Candidate" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
git clone --shared --quiet "$ROOT" "$work/repo"
cd "$work/repo"
git config user.email 'ci@example.invalid'
git config user.name 'CI'
base="$(git rev-parse HEAD)"
fp_base="$(bash scripts/build-fingerprint.sh "$base")"

mkdir -p docs production/accepted-preview
printf 'doc-only\n' >> docs/dedup-contract.md
git add docs/dedup-contract.md
git commit -qm 'test doc only'
doc_head="$(git rev-parse HEAD)"
[[ "$(bash scripts/source-impact-gate.sh "$base" "$doc_head")" == $'NO_FIRMWARE_CHANGE\tDOC_ONLY' ]]
[[ "$(bash scripts/build-fingerprint.sh "$doc_head")" == "$fp_base" ]]

printf '{"stage":"PRODUCTION_RUNNING"}\n' > production/accepted-preview/dedup-contract.json
git add production/accepted-preview/dedup-contract.json
git commit -qm 'test handoff only'
handoff_head="$(git rev-parse HEAD)"
[[ "$(bash scripts/source-impact-gate.sh "$doc_head" "$handoff_head")" == $'NO_FIRMWARE_CHANGE\tFAST_GATE' ]]
[[ "$(bash scripts/build-fingerprint.sh "$handoff_head")" == "$fp_base" ]]

python3 - <<'PY'
import json
from pathlib import Path
for name in ('production/operator-intent.json', 'production/resume-state.json'):
    p = Path(name)
    data = json.loads(p.read_text(encoding='utf-8'))
    data['_dedup_contract_probe'] = 'state-only'
    p.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
with Path('production/firmware-events.jsonl').open('a', encoding='utf-8') as f:
    f.write('{"schema_version":1,"event":"DEDUP_CONTRACT_STATE_ONLY"}\n')
PY
git add production/operator-intent.json production/resume-state.json production/firmware-events.jsonl
git commit -qm 'test state only'
state_head="$(git rev-parse HEAD)"
[[ "$(bash scripts/source-impact-gate.sh "$handoff_head" "$state_head")" == $'NO_FIRMWARE_CHANGE\tFAST_GATE' ]]
[[ "$(bash scripts/build-fingerprint.sh "$state_head")" == "$fp_base" ]]

mkdir -p files/etc/config
printf 'option dedup test\n' > files/etc/config/dedup-contract
git add files/etc/config/dedup-contract
git commit -qm 'test firmware input'
firmware_head="$(git rev-parse HEAD)"
[[ "$(bash scripts/source-impact-gate.sh "$state_head" "$firmware_head")" == $'FIRMWARE_IMPACT\tIMAGEBUILDER' ]]
[[ "$(bash scripts/build-fingerprint.sh "$firmware_head")" != "$fp_base" ]]

mkdir -p "$work/bin"
cat > "$work/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-} ${2:-}" == "run list" ]]; then
  printf '[{"databaseId":33969443771,"headSha":"%s","headBranch":"main","status":"completed","conclusion":"failure","createdAt":"2026-09-05T14:00:00Z"}]\n' "$MOCK_HEAD"
  exit 0
fi
echo "unexpected gh call: $*" >&2
exit 2
EOF
chmod +x "$work/bin/gh"
failed_out="$(PATH="$work/bin:$PATH" MOCK_HEAD="$firmware_head" bash scripts/resolve-candidate-dedup.sh mxonline/xinzhaowrt arthur-update-v3.yml HEAD)"
printf '%s\n' "$failed_out"
grep -qx 'ACTION=REPAIR_FAILED_RUN' <<<"$failed_out"
grep -qx 'RUN_ID=33969443771' <<<"$failed_out"
grep -qx "SOURCE_SHA=$firmware_head" <<<"$failed_out"

echo 'PASS: Arthur Candidate build dedup/source-impact contract is correct.'
