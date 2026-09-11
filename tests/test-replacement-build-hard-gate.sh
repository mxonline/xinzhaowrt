#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
gate="$root/scripts/check-replacement-build-hard-gate.sh"
state="$root/config/replacement-build-gate.env"
workflow="$root/.github/workflows/build.yml"

[[ -x "$gate" ]] || { echo 'FAIL: replacement-build hard gate script is missing or not executable' >&2; exit 1; }
[[ -f "$state" ]] || { echo 'FAIL: replacement-build gate source of truth is missing' >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cp "$state" "$tmp/closed.env"
sed -i 's/^OPENCLASH_OOM_ROOT_CAUSE=.*/OPENCLASH_OOM_ROOT_CAUSE=NOT_PROVEN/' "$tmp/closed.env"
sed -i 's/^OPENCLASH_OOM_FIX=.*/OPENCLASH_OOM_FIX=NOT_READY/' "$tmp/closed.env"
sed -i 's/^OPENCLASH_SIGSEGV_ROOT_CAUSE=.*/OPENCLASH_SIGSEGV_ROOT_CAUSE=NOT_PROVEN/' "$tmp/closed.env"
sed -i 's/^OPENCLASH_SIGSEGV_FIX=.*/OPENCLASH_SIGSEGV_FIX=NOT_READY/' "$tmp/closed.env"
sed -i 's/^OPENCLASH_OOM_EVIDENCE=.*/OPENCLASH_OOM_EVIDENCE=NOT_PROVEN/' "$tmp/closed.env"
sed -i 's/^OPENCLASH_SIGSEGV_EVIDENCE=.*/OPENCLASH_SIGSEGV_EVIDENCE=NOT_PROVEN/' "$tmp/closed.env"
sed -i 's/^OPENCLASH_CONTROLLED_UPDATE=.*/OPENCLASH_CONTROLLED_UPDATE=NOT_PROVEN/' "$tmp/closed.env"
sed -i 's/^STATIC_CHECK=.*/STATIC_CHECK=NOT_RUN/' "$tmp/closed.env"
sed -i 's/^REGRESSION=.*/REGRESSION=NOT_RUN/' "$tmp/closed.env"
sed -i 's/^FAST_GATE=.*/FAST_GATE=NOT_RUN/' "$tmp/closed.env"
sed -i 's/^FINAL_REPLACEMENT_BUILD_ALLOWED=.*/FINAL_REPLACEMENT_BUILD_ALLOWED=false/' "$tmp/closed.env"

set +e
output="$("$gate" "$tmp/closed.env" 2>&1)"
rc=$?
set -e
[[ "$rc" -ne 0 ]] || { echo 'FAIL: NOT_PROVEN state must fail closed' >&2; exit 1; }
grep -Fq 'FINAL_REPLACEMENT_BUILD_ALLOWED=false' <<<"$output" || {
  echo 'FAIL: hard gate did not report the closed initial state' >&2
  exit 1
}

"$gate" "$state" >/dev/null || { echo 'FAIL: current repository gate state is not GREEN' >&2; exit 1; }

cp "$state" "$tmp/stale.env"
sed -i 's/^OPENCLASH_OOM_ROOT_CAUSE=.*/OPENCLASH_OOM_ROOT_CAUSE=NOT_PROVEN/' "$tmp/stale.env"

set +e
stale_output="$("$gate" "$tmp/stale.env" 2>&1)"
stale_rc=$?
set -e
[[ "$stale_rc" -ne 0 ]] || { echo 'FAIL: stale state must not satisfy the hard gate' >&2; exit 1; }
grep -Fq 'STALE' <<<"$stale_output" || { echo 'FAIL: stale-state rejection was not explicit' >&2; exit 1; }

line_of() {
  local pattern="$1"
  grep -nF "$pattern" "$workflow" | head -n1 | cut -d: -f1
}
hard_gate_line="$(line_of '      - name: Replacement build hard gate')"
feed_line="$(line_of '      - name: Feed Check')"
build_line="$(line_of '      - name: Build firmware')"
[[ -n "$hard_gate_line" && -n "$feed_line" && -n "$build_line" ]] || {
  echo 'FAIL: workflow hard gate, Feed Check, and Build firmware steps are required' >&2
  exit 1
}
(( hard_gate_line < feed_line && feed_line < build_line )) || {
  echo 'FAIL: replacement hard gate must precede Feed Check and Build firmware' >&2
  exit 1
}
awk -v start="$hard_gate_line" 'NR >= start && NR <= start + 14 { print }' "$workflow" | grep -Fq 'PUBLISH_CANDIDATE: ${{ github.event.inputs.publish_candidate || '\''true'\'' }}' || {
  echo 'FAIL: hard gate must inspect publish_candidate' >&2
  exit 1
}
grep -Fq 'check-replacement-build-hard-gate.sh config/replacement-build-gate.env' "$workflow" || {
  echo 'FAIL: workflow must invoke the repository hard gate' >&2
  exit 1
}
grep -Fq 'check-replacement-build-hard-gate.sh' "$root/scripts/build.sh" || {
  echo 'FAIL: local build entrypoint must fail closed on the same hard gate' >&2
  exit 1
}

echo 'REPLACEMENT_BUILD_HARD_GATE_TDD=PASS'
