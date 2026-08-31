#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLCHAIN_DIR="${TOOLCHAIN_DIR:-$ROOT/output/toolchain}"
KNOWN_GOOD_JSON="${KNOWN_GOOD_JSON:-$ROOT/production/known-good.json}"
PROVENANCE="$TOOLCHAIN_DIR/toolchain-provenance.json"
CHECKSUMS="$TOOLCHAIN_DIR/SHA256SUMS"
LOCK="$TOOLCHAIN_DIR/arthur-known-good.lock"
ACCEPTANCE="$TOOLCHAIN_DIR/toolchain-acceptance.json"

[[ -d "$TOOLCHAIN_DIR" ]] || { echo "ERROR: toolchain directory missing: $TOOLCHAIN_DIR" >&2; exit 1; }
[[ -s "$KNOWN_GOOD_JSON" ]] || { echo "ERROR: Known-Good JSON missing: $KNOWN_GOOD_JSON" >&2; exit 1; }
[[ -s "$PROVENANCE" ]] || { echo 'ERROR: toolchain provenance missing' >&2; exit 1; }
[[ -s "$CHECKSUMS" ]] || { echo 'ERROR: SHA256SUMS missing' >&2; exit 1; }
[[ -s "$LOCK" ]] || { echo 'ERROR: Known-Good lock missing from toolchain bundle' >&2; exit 1; }
[[ -s "$TOOLCHAIN_DIR/package-repositories.tar.gz" ]] || { echo 'ERROR: package repository archive missing' >&2; exit 1; }

mapfile -t sdk_files < <(find "$TOOLCHAIN_DIR" -maxdepth 1 -type f -iname '*sdk*.tar.*' -printf '%f\n' | sort)
mapfile -t ib_files < <(find "$TOOLCHAIN_DIR" -maxdepth 1 -type f -iname '*imagebuilder*.tar.*' -printf '%f\n' | sort)
(( ${#sdk_files[@]} >= 1 )) || { echo 'ERROR: no SDK archive found in toolchain bundle' >&2; exit 1; }
(( ${#ib_files[@]} >= 1 )) || { echo 'ERROR: no ImageBuilder archive found in toolchain bundle' >&2; exit 1; }

(
  cd "$TOOLCHAIN_DIR"
  sha256sum -c SHA256SUMS
)

mapfile -t KG < <(python3 - "$KNOWN_GOOD_JSON" <<'PY'
import json, re, sys
with open(sys.argv[1], encoding='utf-8') as f:
    d = json.load(f)
status = d.get('status')
if d.get('verified') is not True or status not in {'verified', 'frozen'}:
    raise SystemExit('ERROR: Stable Known-Good is not verified/frozen')
if d.get('verification') != 'real-device-confirmed':
    raise SystemExit('ERROR: Stable Known-Good lacks real-device confirmation')
if d.get('device') != 'jdcloud_re-ss-01':
    raise SystemExit('ERROR: Stable Known-Good device mismatch')
commit = d.get('upstream_commit') or ''
if not re.fullmatch(r'[0-9a-fA-F]{40}', commit):
    raise SystemExit('ERROR: invalid Stable Known-Good upstream commit')
for key in ('stable_tag', 'device', 'target', 'subtarget', 'upstream_commit', 'lock_sha256'):
    print(d.get(key) or '')
PY
)

if (( ${#KG[@]} != 6 )); then
  echo "ERROR: Stable Known-Good parser returned ${#KG[@]} fields; expected 6" >&2
  exit 1
fi

KNOWN_GOOD_TAG="${KG[0]}"
DEVICE="${KG[1]}"
TARGET="${KG[2]}"
SUBTARGET="${KG[3]}"
UPSTREAM_COMMIT="${KG[4]}"
EXPECTED_LOCK_SHA256="${KG[5]}"

actual_lock_sha256="$(sha256sum "$LOCK" | awk '{print $1}')"
[[ -n "$EXPECTED_LOCK_SHA256" ]] || { echo 'ERROR: Stable Known-Good lock SHA256 is empty' >&2; exit 1; }
if [[ "$actual_lock_sha256" != "$EXPECTED_LOCK_SHA256" ]]; then
  echo 'ERROR: toolchain Known-Good lock SHA256 mismatch' >&2
  echo "expected=$EXPECTED_LOCK_SHA256" >&2
  echo "actual=$actual_lock_sha256" >&2
  exit 1
fi

export KNOWN_GOOD_TAG DEVICE TARGET SUBTARGET UPSTREAM_COMMIT EXPECTED_LOCK_SHA256
python3 - "$PROVENANCE" "$ACCEPTANCE" "${sdk_files[*]}" "${ib_files[*]}" <<'PY'
import json, os, sys
from datetime import datetime, timezone

provenance_path, acceptance_path, sdk_joined, ib_joined = sys.argv[1:]
with open(provenance_path, encoding='utf-8') as f:
    p = json.load(f)

expected = {
    'lane': 'TOOLCHAIN_BOOTSTRAP',
    'known_good_tag': os.environ['KNOWN_GOOD_TAG'],
    'device': os.environ['DEVICE'],
    'target': os.environ['TARGET'],
    'subtarget': os.environ['SUBTARGET'],
    'upstream_commit': os.environ['UPSTREAM_COMMIT'],
}
for key, value in expected.items():
    if p.get(key) != value:
        raise SystemExit(f'ERROR: provenance mismatch for {key}: expected {value!r}, got {p.get(key)!r}')

out = {
    'schema_version': '1.0',
    'status': 'verified',
    'lane': 'TOOLCHAIN_BOOTSTRAP',
    'known_good_tag': expected['known_good_tag'],
    'device': expected['device'],
    'target': expected['target'],
    'subtarget': expected['subtarget'],
    'upstream_commit': expected['upstream_commit'],
    'known_good_lock_sha256': os.environ['EXPECTED_LOCK_SHA256'],
    'sdk_archives': sdk_joined.split(),
    'imagebuilder_archives': ib_joined.split(),
    'package_repository': 'package-repositories.tar.gz',
    'checksums': 'SHA256SUMS',
    'verified_at': datetime.now(timezone.utc).isoformat(),
}
with open(acceptance_path, 'w', encoding='utf-8') as f:
    json.dump(out, f, ensure_ascii=False, indent=2)
    f.write('\n')
PY

printf 'TOOLCHAIN_ACCEPTED=%s\n' "$KNOWN_GOOD_TAG"
printf 'ACCEPTANCE=%s\n' "$ACCEPTANCE"
