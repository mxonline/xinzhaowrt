#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KNOWN_GOOD_JSON="${KNOWN_GOOD_JSON:-$ROOT/production/known-good.json}"
LOCK_FILE="${KNOWN_GOOD_LOCK:-$ROOT/config/arthur-known-good.lock}"
WORKDIR="${WORKDIR:-$ROOT/work}"
SRC="$WORKDIR/immortalwrt"
OUT="$ROOT/output/toolchain"
MODE="${1:---execute}"

[[ "$MODE" == "--plan" || "$MODE" == "--execute" ]] || {
  echo "Usage: $0 [--plan|--execute]" >&2
  exit 2
}

[[ -s "$KNOWN_GOOD_JSON" ]] || { echo "ERROR: Known-Good JSON missing: $KNOWN_GOOD_JSON" >&2; exit 1; }
[[ -s "$LOCK_FILE" ]] || { echo "ERROR: Known-Good lock missing: $LOCK_FILE" >&2; exit 1; }

mapfile -t KG < <(python3 - "$KNOWN_GOOD_JSON" <<'PY'
import json, re, sys
p = sys.argv[1]
with open(p, encoding='utf-8') as f:
    d = json.load(f)
status = d.get('status')
# A production Known-Good may be either the original verified state or the
# later immutable/frozen state. Both require explicit verified=true and
# real-device confirmation; candidate/unverified states remain fail-closed.
if d.get('verified') is not True or status not in {'verified', 'frozen'}:
    raise SystemExit('ERROR: Known-Good record is not verified/frozen')
if d.get('verification') != 'real-device-confirmed':
    raise SystemExit('ERROR: Known-Good lacks real-device confirmation')
if d.get('device') != 'jdcloud_re-ss-01':
    raise SystemExit('ERROR: Known-Good device mismatch')
commit = d.get('upstream_commit') or ''
if not re.fullmatch(r'[0-9a-fA-F]{40}', commit):
    raise SystemExit('ERROR: invalid Known-Good upstream commit')
for value in (
    d.get('stable_tag') or '',
    commit,
    d.get('target') or '',
    d.get('subtarget') or '',
    d.get('device') or '',
    d.get('lock_sha256') or '',
):
    print(value)
PY
)

if (( ${#KG[@]} != 6 )); then
  echo "ERROR: Known-Good parser returned ${#KG[@]} fields; expected 6" >&2
  exit 1
fi

KNOWN_GOOD_TAG="${KG[0]}"
UPSTREAM_COMMIT="${KG[1]}"
TARGET="${KG[2]}"
SUBTARGET="${KG[3]}"
PROFILE="${KG[4]}"
EXPECTED_LOCK_SHA256="${KG[5]}"

actual_lock_sha256="$(sha256sum "$LOCK_FILE" | awk '{print $1}')"
if [[ -n "$EXPECTED_LOCK_SHA256" && "$actual_lock_sha256" != "$EXPECTED_LOCK_SHA256" ]]; then
  echo "ERROR: Known-Good lock SHA256 mismatch" >&2
  echo "expected=$EXPECTED_LOCK_SHA256" >&2
  echo "actual=$actual_lock_sha256" >&2
  exit 1
fi

print_plan() {
  cat <<EOF
MODE=PLAN
KNOWN_GOOD_TAG=$KNOWN_GOOD_TAG
UPSTREAM_COMMIT=$UPSTREAM_COMMIT
TARGET=$TARGET/$SUBTARGET
PROFILE=$PROFILE
CONFIG_SDK=y
CONFIG_IB=y
CONFIG_IB_STANDALONE=y
EOF
}

if [[ "$MODE" == "--plan" ]]; then
  print_plan
  exit 0
fi

mkdir -p "$OUT"
rm -rf "$OUT"/*

USE_KNOWN_GOOD_LOCK=1 \
KNOWN_GOOD_LOCK="$LOCK_FILE" \
BUILD_TOOLCHAIN_BUNDLES=1 \
"$ROOT/scripts/build.sh"

TARGET_DIR="$SRC/bin/targets/$TARGET/$SUBTARGET"
[[ -d "$TARGET_DIR" ]] || { echo "ERROR: target output missing: $TARGET_DIR" >&2; exit 1; }

sdk_count=0
ib_count=0
while IFS= read -r -d '' file; do
  base="$(basename "$file")"
  cp -v "$file" "$OUT/$base"
  case "$base" in
    *sdk*.tar.*) sdk_count=$((sdk_count + 1)) ;;
    *imagebuilder*.tar.*) ib_count=$((ib_count + 1)) ;;
  esac
done < <(find "$TARGET_DIR" -maxdepth 1 -type f \( -iname '*sdk*.tar.*' -o -iname '*imagebuilder*.tar.*' \) -print0)

[[ "$sdk_count" -ge 1 ]] || { echo 'ERROR: no SDK archive produced' >&2; exit 1; }
[[ "$ib_count" -ge 1 ]] || { echo 'ERROR: no ImageBuilder archive produced' >&2; exit 1; }

repo_paths=()
[[ -d "$SRC/bin/packages" ]] && repo_paths+=("packages")
[[ -d "$TARGET_DIR/packages" ]] && repo_paths+=("targets/$TARGET/$SUBTARGET/packages")
if (( ${#repo_paths[@]} > 0 )); then
  tar -C "$SRC/bin" -czf "$OUT/package-repositories.tar.gz" "${repo_paths[@]}"
else
  echo 'ERROR: no compiled package repository directories found' >&2
  exit 1
fi

cp "$ROOT/config/arthur-known-good.lock" "$OUT/arthur-known-good.lock"
cp "$ROOT/output/full.config" "$OUT/full.config"
cp "$ROOT/output/build-info.txt" "$OUT/build-info.txt"

PROJECT_COMMIT="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || printf 'unknown')"
GENERATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
export KNOWN_GOOD_TAG UPSTREAM_COMMIT TARGET SUBTARGET PROFILE PROJECT_COMMIT GENERATED_AT
python3 - "$OUT/toolchain-provenance.json" <<'PY'
import json, os, sys
out = sys.argv[1]
d = {
    'schema_version': '1.0',
    'lane': 'TOOLCHAIN_BOOTSTRAP',
    'known_good_tag': os.environ['KNOWN_GOOD_TAG'],
    'device': os.environ['PROFILE'],
    'target': os.environ['TARGET'],
    'subtarget': os.environ['SUBTARGET'],
    'upstream_commit': os.environ['UPSTREAM_COMMIT'],
    'project_commit': os.environ['PROJECT_COMMIT'],
    'generated_at': os.environ['GENERATED_AT'],
    'config': {
        'CONFIG_SDK': 'y',
        'CONFIG_IB': 'y',
        'CONFIG_IB_STANDALONE': 'y',
    },
}
with open(out, 'w', encoding='utf-8') as f:
    json.dump(d, f, ensure_ascii=False, indent=2)
    f.write('\n')
PY

(
  cd "$OUT"
  sha256sum -- * | grep -v ' SHA256SUMS$' > SHA256SUMS
)

printf 'BOOTSTRAP_OK=%s\n' "$KNOWN_GOOD_TAG"
printf 'OUTPUT=%s\n' "$OUT"
