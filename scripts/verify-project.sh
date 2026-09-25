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
  pkg="${pkg%$'\r'}"
  [[ -z "$pkg" || "$pkg" == \#* ]] && continue
  grep -qxF "CONFIG_PACKAGE_${pkg}=y" config/arthur.config || {
    echo "ERROR: config/arthur.config does not enable $pkg"
    exit 1
  }
done < config/required-plugins.txt

./scripts/check-defaults.sh
./scripts/check-upload-oom-fix.sh
./scripts/acceptance-contract-gate.sh

PYTHON_BIN="${PYTHON_BIN:-python3}"
export PYTHON_BIN

for test_script in \
  tests/test-first-boot-defaults.sh \
  tests/test-version-identity.sh \
  tests/test-final-rootfs-identity.sh \
  tests/test-functional-acceptance.sh \
  tests/test-arthur-luci-language-config.sh \
  tests/test-quickstart-template-forensics.sh \
  tests/test-quickstart-final-rootfs-contract.sh \
  tests/test-quickstart-template-parser-fix.sh \
  tests/test-preflight-feed-root.sh \
  tests/test-preflight-path-contract.sh \
  tests/test-final-rootfs-identity-regression.sh \
  tests/test-memory-source-defaults.sh \
  tests/test-memory-source-runtime.sh \
  tests/test-openclash-runtime-forensics.sh \
  tests/test-openclash-core-authority.sh \
  tests/test-failure-classifier.sh \
  tests/test-prebuild-closure.sh \
  tests/test-prebuild-openclash-adh-live-gate.sh \
  tests/test-adguard-overlay-precedence.sh \
  tests/test-replacement-build-hard-gate.sh; do
  bash "$test_script"
done

"$PYTHON_BIN" tests/test-final-rootfs-adh-manager.py
"$PYTHON_BIN" tests/test-openclash-core-bundle.py
"$PYTHON_BIN" tests/test-openclash-smart-core.py
"$PYTHON_BIN" tests/test-openclash-native-runtime.py

if [[ -n "${PREBUILD_PACKAGE_ONLY_ROOT:-}" ]]; then
  PYTHON_BIN="${PYTHON_BIN:-python3}"
  "$PYTHON_BIN" scripts/prebuild-openclash-core-forensics.py \
    --lock "$PREBUILD_PACKAGE_ONLY_ROOT/lock.json" \
    --archive "$PREBUILD_PACKAGE_ONLY_ROOT/archive.tar.gz" \
    --staged "$PREBUILD_PACKAGE_ONLY_ROOT/staged/clash_meta" \
    --pkg-build "$PREBUILD_PACKAGE_ONLY_ROOT/pkg-build/clash_meta" \
    --package "$PREBUILD_PACKAGE_ONLY_ROOT/openclash-core.apk" \
    --package-format "${PREBUILD_PACKAGE_FORMAT:-apk}" \
    --synthetic-rootfs "$PREBUILD_PACKAGE_ONLY_ROOT/rootfs" \
    --package-makefile "$PREBUILD_PACKAGE_ONLY_ROOT/package/Makefile" \
    --package-pack-mk "$PREBUILD_PACKAGE_ONLY_ROOT/package-pack.mk" \
    --rstrip-proof "$PREBUILD_PACKAGE_ONLY_ROOT/rstrip-proof" \
    --output "$PREBUILD_PACKAGE_ONLY_ROOT/forensics.txt"
  echo "PACKAGE_ONLY_OPENCLASH_CORE_FORENSICS=PASS"
fi

if [[ -n "${FEED_CHECK_ROOT:-}" ]]; then
  bash tests/test-adguard-manager.sh
fi

for f in scripts/*.sh; do
  bash -n "$f"
done
sh -n files/etc/uci-defaults/99-xinzhao-defaults

[[ -x scripts/check-package-existence.sh ]] || {
  echo "ERROR: scripts/check-package-existence.sh must be executable"
  exit 1
}

if [[ "${RUN_PREBUILD_CLOSURE_GATE:-0}" == "1" ]]; then
  bash scripts/prebuild-closure.sh
fi

echo "PASS: project static verification complete."
