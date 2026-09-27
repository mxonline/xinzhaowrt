#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT/scripts/check-arthur-final-gates.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

CANDIDATE_SHA="880c52162f7aceb5a85c77ed16591c44a7d847e8"
BASE_CANDIDATE_SHA="c8c57132ed96b97d4687a08bac62a397c8281257"
IMMORTALWRT_SHA="27e26e324bee0b0c2a4eb58e2e9121fea5d43194"
CLOSURE="$TMP/closure.txt"
LIVE="$TMP/live.txt"
SOURCE_BINDING="$TMP/source-binding.txt"
OUT="$TMP/final.txt"

cat > "$CLOSURE" <<EOF
EVIDENCE_TYPE=IMMUTABLE_ZRAM_CLOSURE_BINDING
CLOSURE_RUN_ID=35796805517
ARTIFACT_ID=10726846035
ARTIFACT_NAME=arthur-zram-closure-35796805517
ARTIFACT_DIGEST=sha256:f3b0e910034954063cb5b26f04af5fb125791cc1378066111dea86fc207bc75b
RUN_STATUS=completed
RUN_CONCLUSION=success
RUN_HEAD_SHA=$BASE_CANDIDATE_SHA
ARTHUR_CANDIDATE_SHA=$BASE_CANDIDATE_SHA
IMMORTALWRT_SOURCE_SHA=$IMMORTALWRT_SHA
ZRAM_CONFIG_INCLUDED=PASS
KMOD_ZRAM_COMPILE=PASS
ZRAM_SWAP_PACKAGE_COMPILE=PASS
KERNEL_DEPENDENCY_CLOSURE=PASS
TARGET=qualcommax/ipq60xx
PROFILE=jdcloud_re-ss-01
FIRMWARE_BUILD_COUNT_NEW=0
SOURCE_SHA=$IMMORTALWRT_SHA
EOF
ORIGINAL_BINDING_SHA256="$(sha256sum "$CLOSURE" | awk '{print $1}')"
CHANGED_PATHS_SHA256="$(git -C "$ROOT" diff --name-only "$BASE_CANDIDATE_SHA" "$CANDIDATE_SHA" | LC_ALL=C sort | sha256sum | awk '{print $1}')"

cat > "$SOURCE_BINDING" <<EOF
EVIDENCE_TYPE=DERIVED_ZRAM_SOURCE_APPLICABILITY
CLOSURE_RUN_ID=35796805517
ARTIFACT_ID=10726846035
ARTIFACT_NAME=arthur-zram-closure-35796805517
ARTIFACT_DIGEST=sha256:f3b0e910034954063cb5b26f04af5fb125791cc1378066111dea86fc207bc75b
RUN_STATUS=completed
RUN_CONCLUSION=success
RUN_HEAD_SHA=$BASE_CANDIDATE_SHA
CLOSURE_SOURCE_CANDIDATE_SHA=$BASE_CANDIDATE_SHA
ARTHUR_CANDIDATE_SHA=$CANDIDATE_SHA
IMMORTALWRT_SOURCE_SHA=$IMMORTALWRT_SHA
BASE_CANDIDATE_SHA=$BASE_CANDIDATE_SHA
ZRAM_DIFF_CANDIDATE_SHA=$CANDIDATE_SHA
ORIGINAL_BINDING_SHA256=$ORIGINAL_BINDING_SHA256
ZRAM_RELEVANT_DIFF=0
CHANGED_PATHS_SHA256=$CHANGED_PATHS_SHA256
CLOSURE_REUSE=PASS
ZRAM_CONFIG_INCLUDED=PASS
KMOD_ZRAM_COMPILE=PASS
ZRAM_SWAP_PACKAGE_COMPILE=PASS
KERNEL_DEPENDENCY_CLOSURE=PASS
TARGET=qualcommax/ipq60xx
PROFILE=jdcloud_re-ss-01
FIRMWARE_BUILD_COUNT_NEW=0
EOF

cat > "$LIVE" <<EOF
REAL_DEVICE_FULL_VALIDATION=PASS
FINAL_SOURCE_SHA=$CANDIDATE_SHA
FIRMWARE_BUILD_COUNT_NEW=0
EOF

[[ -s "$GATE" ]] || fail 'final gate script is missing'

if bash "$GATE" --closure "$CLOSURE" --source-binding "$SOURCE_BINDING" --live "$LIVE" --output "$OUT" > "$TMP/missing-candidate.out" 2>&1; then
  fail 'gate accepted evidence without an explicit Arthur candidate SHA'
fi
grep -Fq 'BUILD_ALLOWED=false' "$TMP/missing-candidate.out" || fail 'missing candidate SHA did not fail closed'

if bash "$GATE" --candidate-sha "$CANDIDATE_SHA" --closure "$CLOSURE" --source-binding "$SOURCE_BINDING" --live "$TMP/no-live-evidence.txt" --output "$OUT" > "$TMP/missing-live.out" 2>&1; then
  fail 'gate accepted missing real-device evidence'
fi
grep -Fq 'REAL_DEVICE_FULL_VALIDATION=BLOCKED' "$TMP/missing-live.out" || fail 'missing live evidence was not reported as blocked'
grep -Fq 'BUILD_ALLOWED=false' "$TMP/missing-live.out" || fail 'missing live evidence did not fail closed'

cp "$LIVE" "$TMP/stale-live.txt"
sed -i 's/^FINAL_SOURCE_SHA=.*/FINAL_SOURCE_SHA=0000000000000000000000000000000000000000/' "$TMP/stale-live.txt"
if bash "$GATE" --candidate-sha "$CANDIDATE_SHA" --closure "$CLOSURE" --source-binding "$SOURCE_BINDING" --live "$TMP/stale-live.txt" --output "$OUT" > "$TMP/stale.out" 2>&1; then
  fail 'stale live evidence was accepted'
fi
grep -Fq 'BUILD_ALLOWED=false' "$TMP/stale.out" || fail 'stale-source failure did not fail closed'
grep -Fq 'REAL_DEVICE_FULL_VALIDATION=BLOCKED' "$TMP/stale.out" || fail 'candidate-mismatched live evidence was not reported as blocked'

cp "$SOURCE_BINDING" "$TMP/stale-binding.txt"
sed -i 's/^ARTHUR_CANDIDATE_SHA=.*/ARTHUR_CANDIDATE_SHA=0000000000000000000000000000000000000000/' "$TMP/stale-binding.txt"
if bash "$GATE" --candidate-sha "$CANDIDATE_SHA" --closure "$CLOSURE" --source-binding "$TMP/stale-binding.txt" --live "$LIVE" --output "$OUT" > "$TMP/stale-binding.out" 2>&1; then
  fail 'source binding with a stale Arthur candidate SHA was accepted'
fi
grep -Fq 'BUILD_ALLOWED=false' "$TMP/stale-binding.out" || fail 'stale candidate binding did not fail closed'

cp "$SOURCE_BINDING" "$TMP/failed-run.txt"
sed -i 's/^RUN_CONCLUSION=.*/RUN_CONCLUSION=failure/' "$TMP/failed-run.txt"
if bash "$GATE" --candidate-sha "$CANDIDATE_SHA" --closure "$CLOSURE" --source-binding "$TMP/failed-run.txt" --live "$LIVE" --output "$OUT" > "$TMP/failed-run.out" 2>&1; then
  fail 'source binding from a failed GitHub run was accepted'
fi
grep -Fq 'BUILD_ALLOWED=false' "$TMP/failed-run.out" || fail 'failed-run binding did not fail closed'

cp "$SOURCE_BINDING" "$TMP/nonzero-zram-diff.txt"
sed -i 's/^ZRAM_RELEVANT_DIFF=.*/ZRAM_RELEVANT_DIFF=1/' "$TMP/nonzero-zram-diff.txt"
if bash "$GATE" --candidate-sha "$CANDIDATE_SHA" --closure "$CLOSURE" --source-binding "$TMP/nonzero-zram-diff.txt" --live "$LIVE" --output "$OUT" > "$TMP/nonzero-zram-diff.out" 2>&1; then
  fail 'closure reuse was accepted with a nonzero ZRAM-relevant diff'
fi
grep -Fq 'BUILD_ALLOWED=false' "$TMP/nonzero-zram-diff.out" || fail 'nonzero ZRAM diff did not fail closed'

cp "$CLOSURE" "$TMP/wrong-upstream.txt"
sed -i "s/^SOURCE_SHA=$IMMORTALWRT_SHA$/SOURCE_SHA=$CANDIDATE_SHA/" "$TMP/wrong-upstream.txt"
if bash "$GATE" --candidate-sha "$CANDIDATE_SHA" --closure "$TMP/wrong-upstream.txt" --source-binding "$SOURCE_BINDING" --live "$LIVE" --output "$OUT" > "$TMP/wrong-upstream.out" 2>&1; then
  fail 'closure upstream SHA was conflated with the Arthur candidate SHA'
fi
grep -Fq 'BUILD_ALLOWED=false' "$TMP/wrong-upstream.out" || fail 'upstream/candidate identity mismatch did not fail closed'

bash "$GATE" --candidate-sha "$CANDIDATE_SHA" --closure "$CLOSURE" --source-binding "$SOURCE_BINDING" --live "$LIVE" --output "$OUT" > "$TMP/pass.out"
for marker in \
  ZRAM_CONFIG_INCLUDED=PASS \
  KMOD_ZRAM_COMPILE=PASS \
  ZRAM_SWAP_PACKAGE_COMPILE=PASS \
  KERNEL_DEPENDENCY_CLOSURE=PASS \
  REAL_DEVICE_FULL_VALIDATION=PASS \
  FINAL_SOURCE_FROZEN=PASS \
  EXACT_SOURCE_BINDING=PASS \
  FIRMWARE_BUILD_COUNT_NEW=0 \
  ZRAM_RELEVANT_DIFF=0 \
  CLOSURE_REUSE=PASS \
  BUILD_ALLOWED=true; do
  grep -Fqx "$marker" "$OUT" || fail "final gate output is missing $marker"
done
grep -Fqx "FINAL_SOURCE_SHA=$CANDIDATE_SHA" "$OUT" || fail 'final source SHA is not the frozen Arthur candidate SHA'
grep -Fqx "ARTHUR_CANDIDATE_SHA=$CANDIDATE_SHA" "$OUT" || fail 'final gate did not use the explicit Arthur candidate SHA'
if grep -Fq 'git -C "$PROJECT_ROOT" rev-parse HEAD' "$GATE"; then
  fail 'final gate still derives firmware identity from verifier worktree HEAD'
fi
grep -Fq 'check-arthur-final-gates.sh' "$ROOT/scripts/build.sh" || fail 'formal build entrypoint does not invoke the final gate'
grep -Fq -- '--candidate-sha "$ARTHUR_CANDIDATE_SHA"' "$ROOT/scripts/build.sh" || fail 'formal build entrypoint does not pass the explicit Arthur candidate SHA'
grep -Fq -- '--source-binding "$FINAL_GATE_SOURCE_BINDING"' "$ROOT/scripts/build.sh" || fail 'formal build entrypoint does not pass source-binding evidence'
grep -Fq 'BUILD_ALLOWED=true' "$ROOT/scripts/build.sh" || fail 'formal build entrypoint does not require BUILD_ALLOWED=true'
grep -Fq 'ARTHUR_CANDIDATE_SHA="${ARTHUR_CANDIDATE_SHA:?ERROR: ARTHUR_CANDIDATE_SHA must be supplied explicitly}"' "$ROOT/scripts/build.sh" || fail 'build entrypoint does not require explicit candidate identity'
if grep -Fq 'BUILD_SOURCE_SHA' "$ROOT/scripts/build.sh"; then
  fail 'build gate still couples candidate identity to BUILD_SOURCE_SHA'
fi

# This frozen candidate changes only a comment in config/arthur.config. Its
# effective package and kernel selection is identical to the closure source.
COMMENT_ONLY_CANDIDATE_SHA="17b27fe5f2a90418ee282aaf537ba5fcf5b85151"
COMMENT_ONLY_PATHS_SHA="$(git -C "$ROOT" diff --name-only "$BASE_CANDIDATE_SHA" "$COMMENT_ONLY_CANDIDATE_SHA" | LC_ALL=C sort | sha256sum | awk '{print $1}')"
cp "$SOURCE_BINDING" "$TMP/comment-only-binding.txt"
sed -i \
  -e "s/^ARTHUR_CANDIDATE_SHA=.*/ARTHUR_CANDIDATE_SHA=$COMMENT_ONLY_CANDIDATE_SHA/" \
  -e "s/^ZRAM_DIFF_CANDIDATE_SHA=.*/ZRAM_DIFF_CANDIDATE_SHA=$COMMENT_ONLY_CANDIDATE_SHA/" \
  -e "s/^CHANGED_PATHS_SHA256=.*/CHANGED_PATHS_SHA256=$COMMENT_ONLY_PATHS_SHA/" \
  "$TMP/comment-only-binding.txt"
sed "s/^FINAL_SOURCE_SHA=.*/FINAL_SOURCE_SHA=$COMMENT_ONLY_CANDIDATE_SHA/" "$LIVE" > "$TMP/comment-only-live.txt"
if ! bash "$GATE" --candidate-sha "$COMMENT_ONLY_CANDIDATE_SHA" --closure "$CLOSURE" \
    --source-binding "$TMP/comment-only-binding.txt" --live "$TMP/comment-only-live.txt" \
    --output "$TMP/comment-only.out" > "$TMP/comment-only.log" 2>&1; then
  cat "$TMP/comment-only.log" >&2
  fail 'ZRAM closure reuse rejected a comment-only arthur.config change'
fi
grep -Fqx 'BUILD_ALLOWED=true' "$TMP/comment-only.out" || fail 'comment-only Arthur config change did not pass the final gate'

CHANGED_REPO="$TMP/changed-repo"
mkdir -p "$CHANGED_REPO/scripts" "$CHANGED_REPO/config"
cp "$GATE" "$CHANGED_REPO/scripts/check-arthur-final-gates.sh"
git -C "$CHANGED_REPO" init -q
printf '%s\n' 'CONFIG_PACKAGE_zram-swap=y' > "$CHANGED_REPO/config/arthur.config"
git -C "$CHANGED_REPO" add config/arthur.config
git -C "$CHANGED_REPO" -c user.name=ArthurGate -c user.email=arthur-gate@example.invalid commit -qm baseline
CHANGED_BASE_SHA="$(git -C "$CHANGED_REPO" rev-parse HEAD)"
printf '%s\n' 'CONFIG_PACKAGE_zram-swap=n' > "$CHANGED_REPO/config/arthur.config"
git -C "$CHANGED_REPO" add config/arthur.config
git -C "$CHANGED_REPO" -c user.name=ArthurGate -c user.email=arthur-gate@example.invalid commit -qm changed
CHANGED_CANDIDATE_SHA="$(git -C "$CHANGED_REPO" rev-parse HEAD)"
CHANGED_PATHS_SHA="$(git -C "$CHANGED_REPO" diff --name-only "$CHANGED_BASE_SHA" "$CHANGED_CANDIDATE_SHA" | LC_ALL=C sort | sha256sum | awk '{print $1}')"
sed "s/$BASE_CANDIDATE_SHA/$CHANGED_BASE_SHA/g" "$CLOSURE" > "$TMP/changed-closure.txt"
CHANGED_CLOSURE_SHA="$(sha256sum "$TMP/changed-closure.txt" | awk '{print $1}')"
sed \
  -e "s/$BASE_CANDIDATE_SHA/$CHANGED_BASE_SHA/g" \
  -e "s/$CANDIDATE_SHA/$CHANGED_CANDIDATE_SHA/g" \
  -e "s/^ORIGINAL_BINDING_SHA256=.*/ORIGINAL_BINDING_SHA256=$CHANGED_CLOSURE_SHA/" \
  -e "s/^CHANGED_PATHS_SHA256=.*/CHANGED_PATHS_SHA256=$CHANGED_PATHS_SHA/" \
  "$SOURCE_BINDING" > "$TMP/changed-binding.txt"
sed "s/$CANDIDATE_SHA/$CHANGED_CANDIDATE_SHA/g" "$LIVE" > "$TMP/changed-live.txt"
if bash "$CHANGED_REPO/scripts/check-arthur-final-gates.sh" --candidate-sha "$CHANGED_CANDIDATE_SHA" \
    --closure "$TMP/changed-closure.txt" --source-binding "$TMP/changed-binding.txt" \
    --live "$TMP/changed-live.txt" --output "$TMP/changed.out" > "$TMP/changed.log" 2>&1; then
  fail 'ZRAM closure reuse accepted a changed effective Arthur config'
fi
grep -Fq 'candidate changes effective Arthur config since ZRAM closure' "$TMP/changed.log" || fail 'effective Arthur config change failed for the wrong reason'

echo 'ARTHUR_FINAL_GATES_TEST=PASS'
