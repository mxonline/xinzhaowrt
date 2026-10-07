#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EVIDENCE_DIR="${PREBUILD_CLOSURE_EVIDENCE_DIR:-}"
OUTPUT_DIR="${PREBUILD_CLOSURE_OUTPUT_DIR:-$PROJECT_ROOT/output/prebuild-closure}"
mkdir -p "$OUTPUT_DIR"

FAILED=0
REASONS=()

record_failure() {
  FAILED=1
  REASONS+=("$1")
}

require_marker_file() {
  local file="$1"
  shift
  local path="${EVIDENCE_DIR:-}/$file"
  if [[ -z "$EVIDENCE_DIR" || ! -s "$path" ]]; then
    record_failure "missing evidence: $file"
    return
  fi
  if grep -Eq '(^|=)(FAIL|false)([[:space:]]|$)' "$path"; then
    record_failure "$file contains a failing marker"
  fi
  local marker count
  for marker in "$@"; do
    count="$(grep -Fxc "$marker" "$path" || true)"
    if [[ "$count" != "1" ]]; then
      record_failure "$file requires exactly one $marker (found $count)"
    fi
  done
}

check_candidate_binding() {
  local file="${EVIDENCE_DIR:-}/candidate.txt"
  local head candidate count
  head="$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || true)"
  if [[ ! "$head" =~ ^[0-9a-f]{40}$ ]]; then
    record_failure "cannot resolve current candidate HEAD"
    return
  fi
  if [[ ! -s "$file" ]]; then
    record_failure "missing evidence: candidate.txt"
    return
  fi
  count="$(grep -Ec '^CANDIDATE_SOURCE_SHA=[0-9a-f]{40}$' "$file" || true)"
  candidate="$(sed -n 's/^CANDIDATE_SOURCE_SHA=//p' "$file" | sed -n '1p')"
  if [[ "$count" != "1" || "$candidate" != "$head" ]]; then
    record_failure "candidate evidence is not bound to current HEAD"
  fi
}

check_forensics() {
  local file="${EVIDENCE_DIR:-}/forensics.txt"
  if [[ ! -s "$file" ]]; then
    record_failure "missing evidence: forensics.txt"
    return
  fi
  local official staged pkg_build payload synthetic value count
  local key
  for key in OFFICIAL_LOCKED_CORE_SHA256 STAGED_CORE_SHA256 PKG_BUILD_CORE_SHA256 PACKAGE_PAYLOAD_CORE_SHA256 SYNTHETIC_ROOTFS_CORE_SHA256; do
    count="$(grep -Ec "^${key}=[0-9a-f]{64}$" "$file" || true)"
    if [[ "$count" != "1" ]]; then
      record_failure "forensics requires exactly one valid $key"
    fi
  done
  official="$(sed -n 's/^OFFICIAL_LOCKED_CORE_SHA256=//p' "$file" | sed -n '1p')"
  staged="$(sed -n 's/^STAGED_CORE_SHA256=//p' "$file" | sed -n '1p')"
  pkg_build="$(sed -n 's/^PKG_BUILD_CORE_SHA256=//p' "$file" | sed -n '1p')"
  payload="$(sed -n 's/^PACKAGE_PAYLOAD_CORE_SHA256=//p' "$file" | sed -n '1p')"
  synthetic="$(sed -n 's/^SYNTHETIC_ROOTFS_CORE_SHA256=//p' "$file" | sed -n '1p')"
  if [[ -z "$official" || "$official" != "$staged" || "$official" != "$pkg_build" || "$official" != "$payload" || "$official" != "$synthetic" ]]; then
    record_failure "Core checkpoint SHA256 values are not identical"
  fi
  for value in \
    'CORE_FIRST_DIVERGENCE_STAGE=NONE' \
    'CORE_DIVERGENCE_CAUSE=NONE' \
    'OPENCLASH_CORE_LOCK_VALIDATED=PASS'; do
    count="$(grep -Fxc "$value" "$file" || true)"
    [[ "$count" == "1" ]] || record_failure "forensics missing exactly one $value"
  done
}

check_candidate_binding
check_forensics
require_marker_file known-failure-classes.txt 'ALL_KNOWN_FAILURE_CLASSES=PASS'
require_marker_file package-only-tests.txt \
  'OPENCLASH_CORE_SOURCE_LOCK=PASS' \
  'OPENCLASH_CORE_PACKAGE_COMPILE=PASS' \
  'OPENCLASH_APK_NAMING=PASS' \
  'ADH_APK_NAMING=PASS' \
  'ADH_PACKAGE_MANIFEST=PASS' \
  'ADH_REQUIRED_DEPENDENCIES=PASS' \
  'ADH_WEB_UI=PASS' \
  'OPENCLASH_CORE_FINAL_VERIFIER=PASS' \
  'OPENCLASH_CORE_LIFECYCLE=PASS'
require_marker_file synthetic-rootfs-tests.txt \
  'CORE_SYNTHETIC_ROOTFS=PASS' \
  'ADH_FINAL_ROOTFS_VERIFIER=PASS' \
  'QUICKSTART_SYNTHETIC_RENDER=PASS' \
  'LUCI_TEMPLATE_RENDER=PASS'
require_marker_file final-verifiers.txt \
  'OPENCLASH_FINAL_VERIFIER=PASS' \
  'ADH_FINAL_VERIFIER=PASS' \
  'ADH_LIFECYCLE_START_STOP_RESTART=PASS' \
  'ADH_ENABLE_DISABLE=PASS' \
  'ADH_DEFAULT_STATE=DISABLED'
require_marker_file authority.txt 'NO_AMBIGUOUS_PACKAGE_SOURCE=PASS'
require_marker_file static-tests.txt \
  'FAST_STATIC_TESTS=PASS' \
  'REQUIRED_PLUGINS=PASS' \
  'PACKAGE_EXISTENCE=PASS' \
  'EXPECTED_DIFF=PASS' \
  'UPLOAD_OOM=PASS'
require_marker_file failure-classifier.txt \
  'FAILURE_CLASSIFIER_REAL_RUN_35597970023=PASS' \
  'FAILURE_CLASSIFIER=PASS'

authority_line="OPENCLASH_CORE_PACKAGE_AUTHORITY=UNKNOWN"
divergence_line="CORE_FIRST_DIVERGENCE_STAGE=UNKNOWN"
if [[ -n "$EVIDENCE_DIR" && -s "$EVIDENCE_DIR/authority.txt" ]]; then
  authority_line="$(grep -E '^OPENCLASH_CORE_PACKAGE_AUTHORITY=' "$EVIDENCE_DIR/authority.txt" | sed -n '1p' || true)"
  [[ -n "$authority_line" ]] || authority_line="OPENCLASH_CORE_PACKAGE_AUTHORITY=UNKNOWN"
fi
if [[ -n "$EVIDENCE_DIR" && -s "$EVIDENCE_DIR/forensics.txt" ]]; then
  divergence_line="$(grep -E '^CORE_FIRST_DIVERGENCE_STAGE=' "$EVIDENCE_DIR/forensics.txt" | sed -n '1p' || true)"
  [[ -n "$divergence_line" ]] || divergence_line="CORE_FIRST_DIVERGENCE_STAGE=UNKNOWN"
fi

summary_tmp="$OUTPUT_DIR/.summary.txt.$$"
if (( FAILED == 0 )); then
  printf '%s\n' \
    'ALL_KNOWN_FAILURE_CLASSES=PASS' \
    'PACKAGE_ONLY_TESTS=PASS' \
    'SYNTHETIC_ROOTFS_TESTS=PASS' \
    'ALL_FINAL_VERIFIERS=PASS' \
    'NO_AMBIGUOUS_PACKAGE_SOURCE=PASS' \
    'NO_UNRESOLVED_CORE_WRITER=PASS' \
    'FAILURE_CLASSIFIER=PASS' \
    "$divergence_line" \
    "$authority_line" \
    'PREBUILD_CLOSURE=PASS' \
    'FULL_BUILD_ALLOWED=true' > "$summary_tmp"
  mv -f "$summary_tmp" "$OUTPUT_DIR/summary.txt"
  : > "$OUTPUT_DIR/failures.txt"
  cat "$OUTPUT_DIR/summary.txt"
else
  printf '%s\n' \
    'ALL_KNOWN_FAILURE_CLASSES=FAIL' \
    'PACKAGE_ONLY_TESTS=FAIL' \
    'SYNTHETIC_ROOTFS_TESTS=FAIL' \
    'ALL_FINAL_VERIFIERS=FAIL' \
    'NO_AMBIGUOUS_PACKAGE_SOURCE=FAIL' \
    'NO_UNRESOLVED_CORE_WRITER=FAIL' \
    'FAILURE_CLASSIFIER=FAIL' \
    "$divergence_line" \
    "$authority_line" \
    'PREBUILD_CLOSURE=FAIL' \
    'FULL_BUILD_ALLOWED=false' > "$summary_tmp"
  mv -f "$summary_tmp" "$OUTPUT_DIR/summary.txt"
  printf '%s\n' "${REASONS[@]}" > "$OUTPUT_DIR/failures.txt"
  cat "$OUTPUT_DIR/summary.txt"
  exit 1
fi
