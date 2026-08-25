#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:?Usage: $0 /path/to/immortalwrt}"
cd "$SRC"

cp "$PROJECT_ROOT/config/arthur.config" .config

# iStore upstream currently requires xz-utils to be selected before
# luci-app-store can survive Kconfig/defconfig dependency resolution.
# Keep this compatibility workaround outside the protected Arthur config.
if ! grep -qx 'CONFIG_PACKAGE_xz-utils=y' .config; then
  printf '\nCONFIG_PACKAGE_xz-utils=y\n' >> .config
fi

make defconfig
"$PROJECT_ROOT/scripts/check-config.sh" .config

echo 'PASS: Arthur config survived make defconfig with all required LuCI plugins.'
