#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

COUNT="$(grep -Ev '^[[:space:]]*(#|$)' config/required-plugins.txt | wc -l | tr -d ' ')"
[[ "$COUNT" == "22" ]] || { echo "ERROR: expected 22 mandatory LuCI plugins, found $COUNT"; exit 1; }

if grep -Eq '^[[:space:]]*luci-app-istore([[:space:]]|$)' config/required-plugins.txt; then
  echo "ERROR: luci-app-istore does not exist; use luci-app-store for the official iStore package."
  exit 1
fi

DUPES="$(grep -Ev '^[[:space:]]*(#|$)' config/required-plugins.txt | sort | uniq -d)"
[[ -z "$DUPES" ]] || { echo "ERROR: duplicate plugins:"; echo "$DUPES"; exit 1; }

while IFS= read -r pkg; do
  [[ -z "$pkg" || "$pkg" == \#* ]] && continue
  grep -qxF "CONFIG_PACKAGE_${pkg}=y" config/arthur.config || {
    echo "ERROR: config/arthur.config does not enable $pkg"
    exit 1
  }
done < config/required-plugins.txt

./scripts/check-defaults.sh

for f in scripts/*.sh; do
  bash -n "$f"
done
sh -n files/etc/uci-defaults/99-xinzhao-defaults

[[ -x scripts/check-package-existence.sh ]] || {
  echo "ERROR: scripts/check-package-existence.sh must be executable"
  exit 1
}

echo "PASS: project static verification complete."
