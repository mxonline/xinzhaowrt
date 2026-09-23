#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANDIDATE_SHA=""
CLOSURE_FILE=""
SOURCE_BINDING_FILE=""
LIVE_FILE=""
OUTPUT_FILE="$PROJECT_ROOT/output/arthur-final-gates/markers.txt"

usage() {
  echo "usage: $0 --candidate-sha <sha> --closure <markers.txt> --source-binding <evidence.txt> --live <evidence.txt> [--output <markers.txt>]" >&2
  exit 2
}

while (($#)); do
  case "$1" in
    --candidate-sha) [[ $# -ge 2 ]] || usage; CANDIDATE_SHA="$2"; shift 2 ;;
    --closure) [[ $# -ge 2 ]] || usage; CLOSURE_FILE="$2"; shift 2 ;;
    --source-binding) [[ $# -ge 2 ]] || usage; SOURCE_BINDING_FILE="$2"; shift 2 ;;
    --live) [[ $# -ge 2 ]] || usage; LIVE_FILE="$2"; shift 2 ;;
    --output) [[ $# -ge 2 ]] || usage; OUTPUT_FILE="$2"; shift 2 ;;
    *) usage ;;
  esac
done

FAILED=0
REASONS=()
REAL_DEVICE_STATUS=BLOCKED

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

require_value_once() {
  local file="$1"
  local key="$2"
  local expected="$3"
  local count value
  count="$(grep -Ec "^${key}=.+$" "$file" 2>/dev/null || true)"
  value="$(sed -n "s/^${key}=//p" "$file" | sed -n '1p')"
  [[ "$count" == "1" && "$value" == "$expected" ]] || {
    fail "$file is not bound to $key=$expected"
  }
}

if [[ ! "$CANDIDATE_SHA" =~ ^[0-9a-f]{40}$ ]]; then
  fail 'explicit Arthur candidate SHA is missing or is not a 40-character commit SHA'
fi
if [[ "$CLOSURE_FILE" != /* ]]; then
  CLOSURE_FILE="$PWD/$CLOSURE_FILE"
fi
if [[ "$SOURCE_BINDING_FILE" != /* ]]; then
  SOURCE_BINDING_FILE="$PWD/$SOURCE_BINDING_FILE"
fi
if [[ "$LIVE_FILE" != /* ]]; then
  LIVE_FILE="$PWD/$LIVE_FILE"
fi

require_file "$CLOSURE_FILE"
require_file "$SOURCE_BINDING_FILE"
require_file "$LIVE_FILE"

IMMORTALWRT_SHA=""
BASE_CANDIDATE_SHA=""
if [[ -s "$SOURCE_BINDING_FILE" ]]; then
  for key in \
    CLOSURE_RUN_ID \
    ARTIFACT_ID \
    ARTIFACT_DIGEST \
    RUN_HEAD_SHA \
    CLOSURE_SOURCE_CANDIDATE_SHA \
    ARTHUR_CANDIDATE_SHA \
    IMMORTALWRT_SOURCE_SHA \
    BASE_CANDIDATE_SHA \
    ZRAM_DIFF_CANDIDATE_SHA \
    ORIGINAL_BINDING_SHA256 \
    CHANGED_PATHS_SHA256; do
    count="$(grep -Ec "^${key}=.+$" "$SOURCE_BINDING_FILE" 2>/dev/null || true)"
    [[ "$count" == "1" ]] || fail "$SOURCE_BINDING_FILE requires exactly one $key (found $count)"
  done
  CLOSURE_RUN_ID_VALUE="$(sed -n 's/^CLOSURE_RUN_ID=//p' "$SOURCE_BINDING_FILE" | sed -n '1p')"
  ARTIFACT_ID_VALUE="$(sed -n 's/^ARTIFACT_ID=//p' "$SOURCE_BINDING_FILE" | sed -n '1p')"
  ARTIFACT_DIGEST_VALUE="$(sed -n 's/^ARTIFACT_DIGEST=//p' "$SOURCE_BINDING_FILE" | sed -n '1p')"
  RUN_HEAD_SHA_VALUE="$(sed -n 's/^RUN_HEAD_SHA=//p' "$SOURCE_BINDING_FILE" | sed -n '1p')"
  CLOSURE_SOURCE_SHA_VALUE="$(sed -n 's/^CLOSURE_SOURCE_CANDIDATE_SHA=//p' "$SOURCE_BINDING_FILE" | sed -n '1p')"
  BASE_CANDIDATE_SHA="$(sed -n 's/^BASE_CANDIDATE_SHA=//p' "$SOURCE_BINDING_FILE" | sed -n '1p')"
  ORIGINAL_BINDING_SHA_VALUE="$(sed -n 's/^ORIGINAL_BINDING_SHA256=//p' "$SOURCE_BINDING_FILE" | sed -n '1p')"
  CHANGED_PATHS_SHA_VALUE="$(sed -n 's/^CHANGED_PATHS_SHA256=//p' "$SOURCE_BINDING_FILE" | sed -n '1p')"
  IMMORTALWRT_SHA="$(sed -n 's/^IMMORTALWRT_SOURCE_SHA=//p' "$SOURCE_BINDING_FILE" | sed -n '1p')"
  require_value_once "$SOURCE_BINDING_FILE" EVIDENCE_TYPE DERIVED_ZRAM_SOURCE_APPLICABILITY
  [[ "$CLOSURE_RUN_ID_VALUE" =~ ^[0-9]+$ ]] || fail "$SOURCE_BINDING_FILE has invalid CLOSURE_RUN_ID"
  [[ "$ARTIFACT_ID_VALUE" =~ ^[0-9]+$ ]] || fail "$SOURCE_BINDING_FILE has invalid ARTIFACT_ID"
  [[ "$ARTIFACT_DIGEST_VALUE" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "$SOURCE_BINDING_FILE has invalid ARTIFACT_DIGEST"
  require_value_once "$SOURCE_BINDING_FILE" RUN_STATUS completed
  require_value_once "$SOURCE_BINDING_FILE" RUN_CONCLUSION success
  require_value_once "$SOURCE_BINDING_FILE" ARTIFACT_NAME "arthur-zram-closure-$CLOSURE_RUN_ID_VALUE"
  require_sha_once "$SOURCE_BINDING_FILE" RUN_HEAD_SHA "$RUN_HEAD_SHA_VALUE"
  require_sha_once "$SOURCE_BINDING_FILE" CLOSURE_SOURCE_CANDIDATE_SHA "$RUN_HEAD_SHA_VALUE"
  require_sha_once "$SOURCE_BINDING_FILE" ARTHUR_CANDIDATE_SHA "$CANDIDATE_SHA"
  require_sha_once "$SOURCE_BINDING_FILE" IMMORTALWRT_SOURCE_SHA "$IMMORTALWRT_SHA"
  require_sha_once "$SOURCE_BINDING_FILE" BASE_CANDIDATE_SHA "$RUN_HEAD_SHA_VALUE"
  require_sha_once "$SOURCE_BINDING_FILE" ZRAM_DIFF_CANDIDATE_SHA "$CANDIDATE_SHA"
  [[ "$ORIGINAL_BINDING_SHA_VALUE" =~ ^[0-9a-f]{64}$ ]] || fail "$SOURCE_BINDING_FILE has invalid ORIGINAL_BINDING_SHA256"
  [[ "$CHANGED_PATHS_SHA_VALUE" =~ ^[0-9a-f]{64}$ ]] || fail "$SOURCE_BINDING_FILE has invalid CHANGED_PATHS_SHA256"
  require_value_once "$SOURCE_BINDING_FILE" ZRAM_RELEVANT_DIFF 0
  require_value_once "$SOURCE_BINDING_FILE" CLOSURE_REUSE PASS

  local_original_binding_sha="$(sha256sum "$CLOSURE_FILE" | awk '{print $1}')"
  [[ "$local_original_binding_sha" == "$ORIGINAL_BINDING_SHA_VALUE" ]] || fail 'derived ZRAM applicability does not bind the supplied immutable closure evidence file'
  require_sha_once "$CLOSURE_FILE" RUN_HEAD_SHA "$RUN_HEAD_SHA_VALUE"
  require_sha_once "$CLOSURE_FILE" ARTHUR_CANDIDATE_SHA "$RUN_HEAD_SHA_VALUE"
  require_sha_once "$CLOSURE_FILE" IMMORTALWRT_SOURCE_SHA "$IMMORTALWRT_SHA"

  if [[ "$BASE_CANDIDATE_SHA" =~ ^[0-9a-f]{40}$ && "$CANDIDATE_SHA" =~ ^[0-9a-f]{40}$ ]] \
      && git -C "$PROJECT_ROOT" cat-file -e "$BASE_CANDIDATE_SHA^{commit}" 2>/dev/null \
      && git -C "$PROJECT_ROOT" cat-file -e "$CANDIDATE_SHA^{commit}" 2>/dev/null; then
    if ! git -C "$PROJECT_ROOT" merge-base --is-ancestor "$BASE_CANDIDATE_SHA" "$CANDIDATE_SHA"; then
      fail 'ZRAM closure source is not an ancestor of the requested Arthur candidate'
    else
      changed_paths="$(git -C "$PROJECT_ROOT" diff --name-only "$BASE_CANDIDATE_SHA" "$CANDIDATE_SHA" | LC_ALL=C sort)"
      changed_paths_sha="$(printf '%s\n' "$changed_paths" | sha256sum | awk '{print $1}')"
      [[ "$changed_paths_sha" == "$CHANGED_PATHS_SHA_VALUE" ]] || fail 'candidate changed-file set does not match the derived applicability evidence'
      if grep -Eiq '(^|/)(target/linux|package/kernel|kernel|zram)(/|$)|(^|/)config/[^[:space:]]*(arthur|kernel|zram)|zram' <<<"$changed_paths"; then
        fail 'candidate diff contains a kernel, ZRAM config, package, dependency, or patch change'
      fi
    fi
  else
    fail 'base and candidate source SHAs must resolve to existing Git commits'
  fi
  for marker in \
    'ZRAM_CONFIG_INCLUDED=PASS' \
    'KMOD_ZRAM_COMPILE=PASS' \
    'ZRAM_SWAP_PACKAGE_COMPILE=PASS' \
    'KERNEL_DEPENDENCY_CLOSURE=PASS' \
    'TARGET=qualcommax/ipq60xx' \
    'PROFILE=jdcloud_re-ss-01' \
    'FIRMWARE_BUILD_COUNT_NEW=0' \
    'ZRAM_RELEVANT_DIFF=0' \
    'CLOSURE_REUSE=PASS'; do
    require_once "$SOURCE_BINDING_FILE" "$marker"
  done
fi

if [[ -s "$CLOSURE_FILE" ]]; then
  CLOSURE_SOURCE_SHA="$(sed -n 's/^SOURCE_SHA=//p' "$CLOSURE_FILE" | sed -n '1p')"
  [[ -n "$CLOSURE_SOURCE_SHA" ]] || CLOSURE_SOURCE_SHA="$(sed -n 's/^IMMORTALWRT_SOURCE_SHA=//p' "$CLOSURE_FILE" | sed -n '1p')"
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
  [[ "$CLOSURE_SOURCE_SHA" == "$IMMORTALWRT_SHA" ]] || fail "$CLOSURE_FILE does not bind the frozen ImmortalWrt source SHA"
fi

if [[ -s "$LIVE_FILE" ]]; then
  LIVE_VALIDATION_COUNT="$(grep -Fxc 'REAL_DEVICE_FULL_VALIDATION=PASS' "$LIVE_FILE" 2>/dev/null || true)"
  LIVE_BUILD_COUNT="$(grep -Fxc 'FIRMWARE_BUILD_COUNT_NEW=0' "$LIVE_FILE" 2>/dev/null || true)"
  LIVE_SHA_COUNT="$(grep -Ec '^FINAL_SOURCE_SHA=[0-9a-f]{40}$' "$LIVE_FILE" 2>/dev/null || true)"
  LIVE_SHA_VALUE="$(sed -n 's/^FINAL_SOURCE_SHA=//p' "$LIVE_FILE" | sed -n '1p')"
  if [[ "$LIVE_VALIDATION_COUNT" == "1" && "$LIVE_BUILD_COUNT" == "1" \
      && "$LIVE_SHA_COUNT" == "1" && "$LIVE_SHA_VALUE" == "$CANDIDATE_SHA" ]]; then
    REAL_DEVICE_STATUS=PASS
  fi
  require_once "$LIVE_FILE" 'REAL_DEVICE_FULL_VALIDATION=PASS'
  require_once "$LIVE_FILE" 'FIRMWARE_BUILD_COUNT_NEW=0'
  require_sha_once "$LIVE_FILE" FINAL_SOURCE_SHA "$CANDIDATE_SHA"
fi

if (( FAILED != 0 )); then
  printf '%s\n' \
    "REAL_DEVICE_FULL_VALIDATION=$REAL_DEVICE_STATUS" \
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
  "REAL_DEVICE_FULL_VALIDATION=$REAL_DEVICE_STATUS" \
  "FINAL_SOURCE_SHA=$CANDIDATE_SHA" \
  'FINAL_SOURCE_FROZEN=PASS' \
  'EXACT_SOURCE_BINDING=PASS' \
  "ARTHUR_CANDIDATE_SHA=$CANDIDATE_SHA" \
  "IMMORTALWRT_SOURCE_SHA=$IMMORTALWRT_SHA" \
  "CLOSURE_SOURCE_CANDIDATE_SHA=$RUN_HEAD_SHA_VALUE" \
  "CLOSURE_RUN_ID=$CLOSURE_RUN_ID_VALUE" \
  "ARTIFACT_ID=$ARTIFACT_ID_VALUE" \
  'ZRAM_RELEVANT_DIFF=0' \
  'CLOSURE_REUSE=PASS' \
  'FIRMWARE_BUILD_COUNT_NEW=0' \
  'BUILD_ALLOWED=true' \
  'ARTHUR_FINAL_GATE=PASS' > "$TMP_OUTPUT"
mv -f "$TMP_OUTPUT" "$OUTPUT_FILE"
cat "$OUTPUT_FILE"
