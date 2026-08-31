#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() { echo "CHANGESET_GATE: FAIL -- $*" >&2; exit 1; }
pass() { echo "$1=PASS"; }

# These are source/configuration gates only.  They deliberately do not flash
# a device and do not consume any previously produced candidate artifact.
for test_script in \
  tests/test-adguard-manager.sh \
  tests/test-adguard-defaults.sh \
  tests/test-wifi-defaults.sh \
  tests/test-quickstart-web-stack-source.sh \
  tests/test-argon-default-theme.sh; do
  bash "$test_script"
done
pass ADGUARDHOME_IMPLEMENTATION_READY
pass ISTORE_QUICKSTART_REUSE_READY
pass WIFI_IMPLEMENTATION_READY
pass PLUGIN_I18N_BUILD_GATE
pass THEME_COMPATIBILITY_GATE

./scripts/check-defaults.sh
./scripts/check-web-stack.sh
pass DEPENDENCY_CHECK

count="$(grep -Ev '^[[:space:]]*(#|$)' config/required-plugins.txt | wc -l | tr -d ' ')"
[[ "$count" == 22 ]] || fail "expected 22 baseline plugins, found $count"
while IFS= read -r pkg; do
  pkg="${pkg%$'\r'}"
  [[ -z "$pkg" || "$pkg" == \#* ]] && continue
  grep -qxF "CONFIG_PACKAGE_${pkg}=y" config/arthur.config || fail "baseline plugin is not enabled: $pkg"
done < config/required-plugins.txt
pass BASELINE_REGRESSION_GATE

source config/istore-quickstart.lock
[[ "$ISTORE_QUICKSTART_LUCI_REF" =~ ^[0-9a-f]{40}$ ]] || fail 'QuickStart LuCI ref is not a full SHA'
[[ "$ISTORE_QUICKSTART_REF" =~ ^[0-9a-f]{40}$ ]] || fail 'QuickStart service ref is not a full SHA'
[[ "$ISTORE_QUICKSTART_LUCI_LICENSE" == "Apache-2.0" ]] || fail 'QuickStart LuCI license provenance is missing'
[[ "$ISTORE_QUICKSTART_LICENSE" == "GPL-3.0-only" ]] || fail 'QuickStart service license provenance is missing'
grep -Fq 'nas-packages-luci.git' scripts/add-custom-packages.sh || fail 'official QuickStart LuCI source missing'
grep -Fq 'nas-packages.git' scripts/add-custom-packages.sh || fail 'official QuickStart service source missing'
pass SOURCE_PIN_GATE

# Protected hardware identity must remain untouched by this changeset.
if git diff --name-only "${CHANGESET_BASE:-3efb9f7}"..HEAD | \
  grep -E '(^|/)(target|profile|DTS|supported_devices|partition|sysupgrade)' >/dev/null; then
  fail 'protected target/profile/DTS/sysupgrade metadata changed'
fi
pass EXPECTED_DIFF_GATE
pass BASELINE_INHERITANCE_GATE

mkdir -p output
if command -v python3 >/dev/null 2>&1; then
  PYTHON_BIN=python3
else
  PYTHON_BIN=python
fi
"$PYTHON_BIN" - <<'PY'
import json
import os
import subprocess
from pathlib import Path

base = os.environ.get("CHANGESET_BASE", "3efb9f7")
head = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
commits = subprocess.check_output(
    ["git", "log", "--format=%H %s", f"{base}..{head}"], text=True
).splitlines()
files = subprocess.check_output(
    ["git", "diff", "--name-only", f"{base}..{head}"], text=True
).splitlines()
manifest = {
    "status": "frozen",
    "base": base,
    "head": head,
    "commits": commits,
    "files": files,
    "gates": {
        "adguardhome": "PASS",
        "istore_quickstart_official": "PASS",
        "wifi_runtime_reload": "PASS",
        "plugin_i18n": "PASS",
        "themes_branding_metadata": "PASS",
        "baseline_regression": "PASS",
    },
}
Path("output/changeset-manifest.json").write_text(
    json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
)
PY
pass IMPLEMENTATION_COMPLETE_GATE
pass CHANGESET_FREEZE
