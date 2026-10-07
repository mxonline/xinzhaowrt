#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/evidence"
candidate_sha="$(git -C "$root" rev-parse HEAD)"
printf '%s\n' \
  'OFFICIAL_LOCKED_CORE_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  'STAGED_CORE_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  'PKG_BUILD_CORE_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  'PACKAGE_PAYLOAD_CORE_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  'SYNTHETIC_ROOTFS_CORE_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  'CORE_FIRST_DIVERGENCE_STAGE=NONE' \
  'CORE_DIVERGENCE_CAUSE=NONE' \
  'OPENCLASH_CORE_LOCK_VALIDATED=PASS' > "$tmp/evidence/forensics.txt"
printf 'CANDIDATE_SOURCE_SHA=%s\n' "$candidate_sha" > "$tmp/evidence/candidate.txt"

if PREBUILD_CLOSURE_EVIDENCE_DIR="$tmp/evidence" PREBUILD_CLOSURE_OUTPUT_DIR="$tmp/out" \
  bash "$root/scripts/prebuild-closure.sh" > "$tmp/fail.out" 2>&1; then
  echo 'gate accepted incomplete evidence' >&2
  exit 1
fi
grep -Fq 'PREBUILD_CLOSURE=FAIL' "$tmp/fail.out"
grep -Fq 'FULL_BUILD_ALLOWED=false' "$tmp/fail.out"

printf '%s\n' \
  'ALL_KNOWN_FAILURE_CLASSES=PASS' > "$tmp/evidence/known-failure-classes.txt"
printf '%s\n' \
  'OPENCLASH_CORE_SOURCE_LOCK=PASS' \
  'OPENCLASH_CORE_PACKAGE_COMPILE=PASS' \
  'OPENCLASH_APK_NAMING=PASS' \
  'ADH_APK_NAMING=PASS' \
  'ADH_PACKAGE_MANIFEST=PASS' \
  'ADH_REQUIRED_DEPENDENCIES=PASS' \
  'ADH_WEB_UI=PASS' \
  'OPENCLASH_CORE_FINAL_VERIFIER=PASS' \
  'OPENCLASH_CORE_LIFECYCLE=PASS' > "$tmp/evidence/package-only-tests.txt"
printf '%s\n' \
  'CORE_SYNTHETIC_ROOTFS=PASS' \
  'ADH_FINAL_ROOTFS_VERIFIER=PASS' \
  'QUICKSTART_SYNTHETIC_RENDER=PASS' \
  'LUCI_TEMPLATE_RENDER=PASS' > "$tmp/evidence/synthetic-rootfs-tests.txt"
printf '%s\n' \
  'OPENCLASH_FINAL_VERIFIER=PASS' \
  'ADH_FINAL_VERIFIER=PASS' \
  'ADH_LIFECYCLE_START_STOP_RESTART=PASS' \
  'ADH_ENABLE_DISABLE=PASS' \
  'ADH_DEFAULT_STATE=DISABLED' > "$tmp/evidence/final-verifiers.txt"
printf '%s\n' 'OPENCLASH_CORE_PACKAGE_AUTHORITY=/tmp/source/package/xinzhao/openclash-core' 'NO_AMBIGUOUS_PACKAGE_SOURCE=PASS' > "$tmp/evidence/authority.txt"
printf '%s\n' \
  'FAST_STATIC_TESTS=PASS' \
  'REQUIRED_PLUGINS=PASS' \
  'PACKAGE_EXISTENCE=PASS' \
  'EXPECTED_DIFF=PASS' \
  'UPLOAD_OOM=PASS' > "$tmp/evidence/static-tests.txt"
printf '%s\n' 'FAILURE_CLASSIFIER_REAL_RUN_35597970023=PASS' 'FAILURE_CLASSIFIER=PASS' > "$tmp/evidence/failure-classifier.txt"

PREBUILD_CLOSURE_EVIDENCE_DIR="$tmp/evidence" PREBUILD_CLOSURE_OUTPUT_DIR="$tmp/out" \
  bash "$root/scripts/prebuild-closure.sh" > "$tmp/pass.out"
for marker in \
  ALL_KNOWN_FAILURE_CLASSES=PASS PACKAGE_ONLY_TESTS=PASS SYNTHETIC_ROOTFS_TESTS=PASS \
  ALL_FINAL_VERIFIERS=PASS NO_AMBIGUOUS_PACKAGE_SOURCE=PASS NO_UNRESOLVED_CORE_WRITER=PASS \
  FAILURE_CLASSIFIER=PASS PREBUILD_CLOSURE=PASS FULL_BUILD_ALLOWED=true; do
  grep -Fq "$marker" "$tmp/pass.out"
done

printf '%s\n' 'CONTRADICTORY=FAIL' >> "$tmp/evidence/static-tests.txt"
if PREBUILD_CLOSURE_EVIDENCE_DIR="$tmp/evidence" PREBUILD_CLOSURE_OUTPUT_DIR="$tmp/out" \
  bash "$root/scripts/prebuild-closure.sh" > "$tmp/contradictory.out" 2>&1; then
  echo 'gate accepted contradictory evidence' >&2
  exit 1
fi
grep -Fq 'FULL_BUILD_ALLOWED=false' "$tmp/contradictory.out"
grep -Fq 'FULL_BUILD_ALLOWED=false' "$tmp/out/summary.txt"

sed -i '/^CONTRADICTORY=FAIL$/d' "$tmp/evidence/static-tests.txt"
PREBUILD_CLOSURE_EVIDENCE_DIR="$tmp/evidence" PREBUILD_CLOSURE_OUTPUT_DIR="$tmp/out" \
  bash "$root/scripts/prebuild-closure.sh" > "$tmp/pass-again.out"
grep -Fq 'FULL_BUILD_ALLOWED=true' "$tmp/out/summary.txt"

grep -Fq 'prebuild-closure.sh' "$root/scripts/verify-project.sh"
grep -Fq 'RUN_PREBUILD_CLOSURE_GATE' "$root/scripts/verify-project.sh"
grep -Fq 'test-openclash-core-authority.sh' "$root/scripts/verify-project.sh"
grep -Fq 'test-prebuild-closure.sh' "$root/scripts/verify-project.sh"
echo 'PREBUILD_CLOSURE_GATE_TEST=PASS'
