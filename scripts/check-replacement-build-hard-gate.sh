#!/usr/bin/env bash
set -euo pipefail

state="${1:-}"
[[ -n "$state" && -f "$state" ]] || {
  echo 'REPLACEMENT_BUILD_HARD_GATE: FAIL -- missing state file' >&2
  exit 1
}

declare -A values=()
while IFS='=' read -r key value; do
  [[ -z "${key//[[:space:]]/}" || "$key" == \#* ]] && continue
  value="${value%$'\r'}"
  [[ "$key" =~ ^[A-Z0-9_]+$ ]] || {
    echo "REPLACEMENT_BUILD_HARD_GATE: FAIL -- invalid key: $key" >&2
    exit 1
  }
  [[ -z "${values[$key]+present}" ]] || {
    echo "REPLACEMENT_BUILD_HARD_GATE: FAIL -- duplicate key: $key" >&2
    exit 1
  }
  values[$key]="$value"
done < "$state"

required=(
  QUICKSTART_ROOT_CAUSE QUICKSTART_FIX
  VERSION_IDENTITY_ROOT_CAUSE VERSION_IDENTITY_FIX
  OPENCLASH_OOM_ROOT_CAUSE OPENCLASH_OOM_FIX
  OPENCLASH_SIGSEGV_ROOT_CAUSE OPENCLASH_SIGSEGV_FIX
  OPENCLASH_OOM_EVIDENCE OPENCLASH_SIGSEGV_EVIDENCE OPENCLASH_CONTROLLED_UPDATE
  STATIC_CHECK REGRESSION FAST_GATE FINAL_REPLACEMENT_BUILD_ALLOWED
)
expected=(
  PROVEN READY
  PROVEN READY
  PROVEN READY
  PROVEN READY
  PASS PASS PASS
  PASS PASS PASS true
)

failed=0
for i in "${!required[@]}"; do
  key="${required[$i]}"
  want="${expected[$i]}"
  if [[ "${values[$key]+present}" != present ]]; then
    echo "REPLACEMENT_BUILD_HARD_GATE: FAIL -- missing $key (expected $want)" >&2
    failed=1
  elif [[ "${values[$key]}" != "$want" ]]; then
    echo "REPLACEMENT_BUILD_HARD_GATE: FAIL -- $key=${values[$key]} (expected $want)" >&2
    failed=1
  fi
done

if (( failed )); then
  echo 'REPLACEMENT_BUILD_HARD_GATE: FAIL -- STALE_OR_UNREADY_STATE' >&2
  echo "REPLACEMENT_BUILD_HARD_GATE: FAIL -- FINAL_REPLACEMENT_BUILD_ALLOWED=${values[FINAL_REPLACEMENT_BUILD_ALLOWED]:-missing}" >&2
  exit 1
fi

echo 'REPLACEMENT_BUILD_HARD_GATE: PASS'
echo 'FINAL_REPLACEMENT_BUILD_ALLOWED=true'
