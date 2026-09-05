#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LINKER="$ROOT/scripts/add-custom-packages.sh"
CHECKER="$ROOT/scripts/check-package-sources.sh"

# The provenance gate must validate the same sources that the linker actually exposes.
grep -Fq 'link_pkg luci-app-quickstart "$ISTOREOS_LUCI/luci/luci-app-quickstart"' "$LINKER" || {
  echo 'FAIL: QuickStart linker no longer uses the accepted iStoreOS LuCI source.' >&2
  exit 1
}
grep -Fq 'link_pkg luci-app-adguardhome "$ADGUARD_MATURE/luci-app-adguardhome"' "$LINKER" || {
  echo 'FAIL: AdGuard linker no longer uses the accepted mature Kenzok8 source.' >&2
  exit 1
}

grep -Fq 'ISTOREOS_LUCI_SOURCE="$SRC/.xinzhao-sources/istoreos-luci"' "$CHECKER" || {
  echo 'FAIL: provenance checker does not declare the accepted iStoreOS LuCI source.' >&2
  exit 1
}
grep -Fq 'ADGUARD_MATURE_SOURCE="$SRC/.xinzhao-sources/kenzok8-adguardhome"' "$CHECKER" || {
  echo 'FAIL: provenance checker does not declare the accepted mature AdGuard source.' >&2
  exit 1
}
grep -Fq 'assert_source luci-app-quickstart "$ISTOREOS_LUCI_SOURCE/luci/luci-app-quickstart"' "$CHECKER" || {
  echo 'FAIL: QuickStart provenance assertion is not aligned with the linker.' >&2
  exit 1
}
grep -Fq 'assert_source luci-app-adguardhome "$ADGUARD_MATURE_SOURCE/luci-app-adguardhome"' "$CHECKER" || {
  echo 'FAIL: AdGuard provenance assertion is not aligned with the linker.' >&2
  exit 1
}

if grep -Fq 'assert_source luci-app-quickstart "$KENZO_SOURCE/luci-app-quickstart"' "$CHECKER"; then
  echo 'FAIL: obsolete QuickStart Kenzok8 provenance assertion remains.' >&2
  exit 1
fi
if grep -Fq 'assert_source luci-app-adguardhome "$IMMORTAL_LUCI_SOURCE/applications/luci-app-adguardhome"' "$CHECKER"; then
  echo 'FAIL: obsolete AdGuard ImmortalWrt provenance assertion remains.' >&2
  exit 1
fi

echo 'PACKAGE_SOURCE_PROVENANCE_CONTRACT=PASS'
