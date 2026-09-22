#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLOSURE_FILE=""
LIVE_FILE=""
OUTPUT_FILE="$PROJECT_ROOT/output/arthur-final-gates/markers.txt"

usage() {
  echo "usage: $0 --closure <markers.txt> --live <evidence.txt> [--output <markers.txt>]" >&2
  exit 2
}

while (($#)); do
  case "$1" in
    --closure) [[ $# -ge 2 ]] || usage; CLOSURE_FILE="$2"; shift 2 ;;
    --live) [[ $# -ge 2 ]] || usage; LIVE_FILE="$2"; shift 2 ;;
    --output) [[ $# -ge 2 ]] || usage; OUTPUT_FILE="$2"; shift 2 ;;
    *) usage ;;
  esac
done

HEAD="$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || true)"
FAILED=0
REASONS=()

fail() {
  FAILED=1
  REASONS+=("$1")
}

require_file() {
  local file="$1"
  [[ -s "$file" ]] || fail "missing evidence file: $file"
}

require_once() {
  local file="$1"
  local marker="$2"
  local count
  count="$(grep -Fxc "$marker" "$file" 2>/dev/null || true)"
  [[ "$count" == "1" ]] || fail "$file requires exactly one $marker (found $count)"
}

require_sha_once() {
  local file="$1"
  local key="$2"
  local expected="$3"
  local count value
  count="$(grep -Ec "^${key}=[0-9a-f]{40}$" "$file" 2>/dev/null || true)"
  value="$(sed -n "s/^${key}=//p" "$file" | sed -n '1p')"
  [[ "$count" == "1" && "$value" == "$expected" ]] || {
    fail "$file is not bound to $key=$expected"
  }
}

if [[ ! "$HEAD" =~ ^[0-9a-f]{40}$ ]]; then
  fail 'current source HEAD is not a 40-character commit SHA'
fi
if [[ "$CLOSURE_FILE" != /* ]]; then
  CLOSURE_FILE="$PWD/$CLOSURE_FILE"
fi
if [[ "$LIVE_FILE" != /* ]]; then
  LIVE_FILE="$PWD/$LIVE_FILE"
fi

require_file "$CLOSURE_FILE"
require_file "$LIVE_FILE"

if [[ -s "$CLOSURE_FILE" ]]; then
  for marker in \
    'ZRAM_CONFIG_INCLUDED=PASS' \
    'KMOD_ZRAM_COMPILE=PASS' \
    'ZRAM_SWAP_PACKAGE_COMPILE=PASS' \
    'KERNEL_DEPENDENCY_CLOSURE=PASS' \
    'TARGET=qualcommax/ipq60xx' \
    'PROFILE=jdcloud_re-ss-01' \
    'FIRMWARE_BUILD_COUNT_NEW=0'; do
    require_once "$CLOSURE_FILE" "$marker"
  done
  require_sha_once "$CLOSURE_FILE" SOURCE_SHA "$HEAD"
fi

if [[ -s "$LIVE_FILE" ]]; then
  require_once "$LIVE_FILE" 'REAL_DEVICE_FULL_VALIDATION=PASS'
  require_once "$LIVE_FILE" 'FIRMWARE_BUILD_COUNT_NEW=0'
  require_sha_once "$LIVE_FILE" FINAL_SOURCE_SHA "$HEAD"
fi

if (( FAILED != 0 )); then
  printf '%s\n' \
    'FINAL_SOURCE_FROZEN=FAIL' \
    'EXACT_SOURCE_BINDING=FAIL' \
    'FIRMWARE_BUILD_COUNT_NEW=0' \
    'BUILD_ALLOWED=false' \
    'ARTHUR_FINAL_GATE=FAIL'
  printf 'ERROR: %s\n' "${REASONS[@]}" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT_FILE")"
TMP_OUTPUT="${OUTPUT_FILE}.tmp.$$"
printf '%s\n' \
  'ZRAM_CONFIG_INCLUDED=PASS' \
  'KMOD_ZRAM_COMPILE=PASS' \
  'ZRAM_SWAP_PACKAGE_COMPILE=PASS' \
  'KERNEL_DEPENDENCY_CLOSURE=PASS' \
  'REAL_DEVICE_FULL_VALIDATION=PASS' \
  "FINAL_SOURCE_SHA=$HEAD" \
  'FINAL_SOURCE_FROZEN=PASS' \
  'EXACT_SOURCE_BINDING=PASS' \
  'FIRMWARE_BUILD_COUNT_NEW=0' \
  'BUILD_ALLOWED=true' \
  'ARTHUR_FINAL_GATE=PASS' > "$TMP_OUTPUT"
mv -f "$TMP_OUTPUT" "$OUTPUT_FILE"
cat "$OUTPUT_FILE"
