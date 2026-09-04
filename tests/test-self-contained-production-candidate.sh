#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
config="$root/config/arthur.config"
packages="$root/scripts/add-custom-packages.sh"
manifest="$root/production/accepted-preview/arthur-adh-quickstart.json"

grep -Fxq 'CONFIG_PACKAGE_luci-theme-argon=y' "$config" || { echo 'FAIL: production config must embed Argon.' >&2; exit 1; }
grep -Fxq 'CONFIG_PACKAGE_luci-theme-kucat=y' "$config" || { echo 'FAIL: production config must embed KuCat.' >&2; exit 1; }
grep -Fq 'config/arthur-theme.lock' "$packages" || { echo 'FAIL: production package assembly must consume the frozen Arthur theme lock.' >&2; exit 1; }
grep -Fq 'jerrykuku/luci-theme-argon.git' "$packages" || { echo 'FAIL: production package assembly must use the frozen Argon source.' >&2; exit 1; }
grep -Fq 'sirpdboy/luci-theme-kucat.git' "$packages" || { echo 'FAIL: production package assembly must use the frozen KuCat source.' >&2; exit 1; }
grep -Fq 'link_pkg luci-theme-argon' "$packages" || { echo 'FAIL: Argon must enter the production xinzhao feed.' >&2; exit 1; }
grep -Fq 'link_pkg luci-theme-kucat' "$packages" || { echo 'FAIL: KuCat must enter the production xinzhao feed.' >&2; exit 1; }

[[ -s "$manifest" ]] || { echo 'FAIL: accepted arthur-adh-quickstart manifest is missing from the production source.' >&2; exit 1; }
python3 - "$root" "$manifest" <<'PY'
import hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
manifest = json.load(open(sys.argv[2], encoding='utf-8'))
files = manifest.get('frozen_files') or []
if not files:
    raise SystemExit('FAIL: accepted preview manifest has no frozen_files')
for item in files:
    overlay = item.get('overlay')
    expected = item.get('sha256')
    if not overlay or not expected:
        raise SystemExit(f'FAIL: malformed frozen file entry: {item!r}')
    path = root / overlay
    if not path.is_file():
        raise SystemExit(f'FAIL: accepted overlay missing from firmware input: {overlay}')
    actual = hashlib.sha256(path.read_bytes()).hexdigest()
    if actual != expected:
        raise SystemExit(f'FAIL: accepted overlay hash drift: {overlay} expected={expected} actual={actual}')
print(f'ACCEPTED_PREVIEW_EMBEDDED=PASS files={len(files)}')
PY

echo 'SELF_CONTAINED_PRODUCTION_CANDIDATE=PASS'
