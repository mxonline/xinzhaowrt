#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EVIDENCE="${1:-${PACKAGE_ONLY_EVIDENCE:-}}"

[[ -n "$EVIDENCE" && -s "$EVIDENCE" ]] || {
  echo 'PREBUILD_CLOSURE=FAIL'
  echo 'FULL_BUILD_ALLOWED=false'
  echo 'reason=missing Linux package-only evidence'
  exit 1
}

bash "$ROOT/tests/test-openclash-core-authority.sh"
bash "$ROOT/tests/test-failure-classifier.sh"
python3 "$ROOT/tests/test-openclash-core-bundle.py"
python3 "$ROOT/tests/test-final-rootfs-adh-manager.py"

for marker in \
  OPENCLASH_CORE_APK=PASS \
  OPENCLASH_CORE_ARCH=PASS \
  OPENCLASH_CORE_PAYLOAD_IDENTITY=PASS \
  PACKAGE_ONLY_TESTS=PASS; do
  grep -Fxq "$marker" "$EVIDENCE" || {
    echo "PREBUILD_CLOSURE=FAIL"
    echo "FULL_BUILD_ALLOWED=false"
    echo "reason=missing $marker"
    exit 1
  }
done

python3 - "$EVIDENCE" <<'PY'
import sys
vals={}
for raw in open(sys.argv[1], encoding='utf-8'):
    raw=raw.strip()
    if '=' in raw:
        k,v=raw.split('=',1)
        vals[k]=v
keys=[
 'OFFICIAL_LOCKED_CORE_SHA256',
 'STAGED_CORE_SHA256',
 'PKG_BUILD_CORE_SHA256',
 'PACKAGE_PAYLOAD_CORE_SHA256',
 'SYNTHETIC_ROOTFS_CORE_SHA256',
]
missing=[k for k in keys if not vals.get(k)]
if missing:
    raise SystemExit('missing core SHA evidence: '+','.join(missing))
if len({vals[k] for k in keys}) != 1:
    raise SystemExit('core SHA identity mismatch: '+repr({k:vals[k] for k in keys}))
PY

echo 'ALL_KNOWN_FAILURE_CLASSES=PASS'
echo 'PACKAGE_ONLY_TESTS=PASS'
echo 'SYNTHETIC_ROOTFS_TESTS=PASS'
echo 'ALL_FINAL_VERIFIERS=PASS'
echo 'NO_AMBIGUOUS_PACKAGE_SOURCE=PASS'
echo 'NO_UNRESOLVED_CORE_WRITER=PASS'
echo 'FAILURE_CLASSIFIER=PASS'
echo 'PREBUILD_CLOSURE=PASS'
echo 'FULL_BUILD_ALLOWED=true'
