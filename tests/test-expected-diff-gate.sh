#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKER="$ROOT/scripts/check-expected-diff.py"
PYTHON_BIN="${PYTHON_BIN:-python3}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "EXPECTED_DIFF_GATE_TEST: FAIL -- $*" >&2; exit 1; }

git -C "$TMP" init -q
git -C "$TMP" config user.name 'Expected Diff Test'
git -C "$TMP" config user.email 'expected-diff-test@example.invalid'
mkdir -p "$TMP/production"
cat > "$TMP/production/expected-diff.json" <<'EOF'
{
  "schema_version": "1.0",
  "baseline": "production/real-device-baseline.json",
  "status": "READY",
  "comparison_base_source_sha": "0000000000000000000000000000000000000000",
  "allowed_paths": []
}
EOF
printf '0.1.5\n' > "$TMP/VERSION"
git -C "$TMP" add production/expected-diff.json VERSION
git -C "$TMP" commit -qm 'fixture: establish expected diff base'
base="$(git -C "$TMP" rev-parse HEAD)"

cat > "$TMP/production/expected-diff.json" <<EOF
{
  "schema_version": "1.0",
  "baseline": "production/real-device-baseline.json",
  "status": "READY",
  "comparison_base_source_sha": "$base",
  "allowed_paths": ["VERSION", "production/expected-diff.json"]
}
EOF
printf '0.1.6\n' > "$TMP/VERSION"
git -C "$TMP" add production/expected-diff.json VERSION
git -C "$TMP" commit -qm 'fixture: declare metadata-only diff'

pass_output="$("$PYTHON_BIN" "$CHECKER" --root "$TMP" 2>&1)" || fail "declared paths were rejected: $pass_output"
grep -Fq 'EXPECTED_DIFF_GATE=PASS' <<<"$pass_output" || fail 'pass marker is missing'

printf 'unexpected\n' > "$TMP/undeclared.txt"
git -C "$TMP" add undeclared.txt
git -C "$TMP" commit -qm 'fixture: add undeclared path'
set +e
fail_output="$("$PYTHON_BIN" "$CHECKER" --root "$TMP" 2>&1)"
fail_rc=$?
set -e
[[ "$fail_rc" -ne 0 ]] || fail 'undeclared path was accepted'
grep -Fq 'UNDECLARED_CHANGED_PATHS=undeclared.txt' <<<"$fail_output" || fail "specific undeclared path was not reported: $fail_output"

echo 'EXPECTED_DIFF_GATE_REGRESSION=PASS'
