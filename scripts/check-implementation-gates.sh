#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

fail() { echo "IMPLEMENTATION_GATES: FAIL -- $*" >&2; exit 1; }
pass() { echo "$1=PASS"; }

base_ref="${ARTHUR_FROZEN_BASE_REF:-origin/main}"
git rev-parse --verify "$base_ref^{commit}" >/dev/null 2>&1 ||
  fail "frozen comparison ref is unavailable: $base_ref"

git merge-base --is-ancestor bdb4658a2e34a9de2153b2765161ba63f7258089 HEAD ||
  fail 'candidate source is not based on the required Arthur v0.1.3 target commit'

[[ ! -e files/www/luci-static/resources/view/adguardhome/config.js ]] ||
  fail 'project AdGuard overlay would replace the mature upstream manager'
[[ ! -e files/usr/share/rpcd/acl.d/luci-app-adguardhome.json ]] ||
  fail 'project AdGuard ACL overlay would replace the mature upstream ACL'

grep -Fq 'immortalwrt/luci.git' scripts/add-custom-packages.sh ||
  fail 'mature AdGuard manager source is not sourced from official ImmortalWrt LuCI'
grep -Fq 'luci-app-adguardhome' scripts/add-custom-packages.sh ||
  fail 'official AdGuard LuCI package is not selected'

grep -Fq 'nas-packages-luci.git' scripts/add-custom-packages.sh ||
  fail 'official iStoreOS QuickStart LuCI source is missing'
grep -Fq 'nas-packages.git' scripts/add-custom-packages.sh ||
  fail 'official iStoreOS QuickStart service source is missing'
grep -Fq 'ISTORE_QUICKSTART_LUCI_REF' scripts/add-custom-packages.sh ||
  fail 'QuickStart LuCI source is not pinned'
grep -Fq 'ISTORE_QUICKSTART_REF' scripts/add-custom-packages.sh ||
  fail 'QuickStart service source is not pinned'
grep -Fq 'quickstart.$(PKG_ARCH_quickstart)' scripts/add-custom-packages.sh ||
  fail 'QuickStart target-architecture artifact selector is missing'

python_bin="${PYTHON_BIN:-}"
if [[ -z "$python_bin" ]]; then
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import sys' >/dev/null 2>&1; then
    python_bin=python3
  elif command -v python >/dev/null 2>&1 && python -c 'import sys' >/dev/null 2>&1; then
    python_bin=python
  fi
fi
command -v "$python_bin" >/dev/null 2>&1 ||
  fail 'Python 3 is required for canonical frozen-file hashing'
for frozen_spec in \
  'build.env:E6F729E7A1DBC6A56FE6662BD3B956CD8F83B0E16DB4EEB57F2882A28D5752C9' \
  'files/etc/uci-defaults/98-xinzhao-wifi-defaults:439777CABBBA189E3CC53E6AEF5D695B55DE541B8006066C371EC6EA8414ED46' \
  'files/etc/uci-defaults/99-xinzhao-defaults:A639E4E152F8EF4F9D582B4D94F058360DDE5E7D7D2285939E879E6F2390FEAA'; do
  frozen_file="${frozen_spec%%:*}"
  frozen_expected="${frozen_spec#*:}"
  frozen_actual="$("$python_bin" - "$frozen_file" <<'PY'
import hashlib
import pathlib
import sys
data = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").replace("\r\n", "\n").replace("\r", "\n").encode()
print(hashlib.sha256(data).hexdigest().upper())
PY
)"
  [[ "$frozen_actual" == "$frozen_expected" ]] ||
    fail "frozen Wi-Fi/default file changed: $frozen_file"
done

grep -Fq 'ARTHUR_LUCI_COOKIE_FILE' scripts/real-device-verify.ps1 ||
  fail 'real-device verification must require an authenticated LuCI session'
grep -Fq 'adguard_page_functional' scripts/real-device-verify.ps1 ||
  fail 'real-device verification lacks AdGuard page functionality'
grep -Fq '/cgi-bin/luci/admin/quickstart/' scripts/real-device-verify.ps1 ||
  fail 'real-device verification lacks the official QuickStart route'
grep -Fq 'quickstart_home_functional' scripts/real-device-verify.ps1 ||
  fail 'real-device verification lacks QuickStart homepage functionality'
grep -Fq 'wifi_configuration_mutated = $false' scripts/real-device-verify.ps1 ||
  fail 'real-device verification does not prove Wi-Fi was read-only'
! grep -R -n -E 'uci[[:space:]]+([^;]*[[:space:]])?set[[:space:]]+wireless\.|uci[[:space:]]+commit[[:space:]]+wireless|wifi reload' \
  scripts/live-validate-v013-features.ps1 >/dev/null 2>&1 ||
  fail 'active live validation script contains forbidden Wi-Fi mutation'

source config/istore-quickstart.lock
[[ "$ISTORE_QUICKSTART_LUCI_REF" =~ ^[0-9a-f]{40}$ ]] ||
  fail 'QuickStart LuCI lock is not a full commit SHA'
[[ "$ISTORE_QUICKSTART_REF" =~ ^[0-9a-f]{40}$ ]] ||
  fail 'QuickStart service lock is not a full commit SHA'

out="$root/output"
mkdir -p "$out"
"$python_bin" - "$out/implementation-gate.json" "$base_ref" <<'PY'
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

path, base_ref = sys.argv[1:]
head = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
payload = {
    "schema_version": "1.0",
    "status": "PASS",
    "gate": "V013_IMPLEMENTATION_GATES",
    "FIRMWARE_BUILD_ALLOWED": "true",
    "RELEASE_ALLOWED": "false",
    "WIFI": "VERIFIED_FROZEN",
    "ADGUARD_REAL_DEVICE": "NOT_RUN",
    "QUICKSTART_REAL_DEVICE": "NOT_RUN",
    "source_head": head,
    "frozen_comparison_ref": base_ref,
    "validated_at": datetime.now(timezone.utc).isoformat(),
}
Path(path).write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY

pass V013_IMPLEMENTATION_GATES
echo 'WIFI=VERIFIED_FROZEN'
echo 'ADGUARD_REAL_DEVICE=NOT_RUN'
echo 'QUICKSTART_REAL_DEVICE=NOT_RUN'
echo 'FIRMWARE_BUILD_ALLOWED=true'
echo 'RELEASE_ALLOWED=false'
