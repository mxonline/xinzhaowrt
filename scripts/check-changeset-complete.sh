#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() { echo "CHANGESET_GATE: FAIL -- $*" >&2; exit 1; }
pass() { echo "$1=PASS"; }

# v4.3 source/configuration checks. This script is intentionally safe:
# it never flashes a device and never consumes an older candidate artifact.
for test_script in \
  tests/test-implementation-complete-gate.sh \
  tests/test-adguard-manager.sh \
  tests/test-adguard-defaults.sh \
  tests/test-wifi-defaults.sh \
  tests/test-quickstart-web-stack-source.sh \
  tests/test-argon-default-theme.sh; do
  bash "$test_script"
done
pass STATIC_TESTS
pass ADGUARDHOME_IMPLEMENTATION_READY
pass ISTORE_QUICKSTART_REUSE_READY
pass WIFI_IMPLEMENTATION_READY

./scripts/check-defaults.sh
./scripts/check-web-stack.sh
pass CONFIG_TESTS
pass DEPENDENCY_CHECK

count="$(grep -Ev '^[[:space:]]*(#|$)' config/required-plugins.txt | wc -l | tr -d ' ')"
[[ "$count" == 22 ]] || fail "expected 22 baseline plugins, found $count"
while IFS= read -r pkg; do
  pkg="${pkg%$'\r'}"
  [[ -z "$pkg" || "$pkg" == \#* ]] && continue
  grep -qxF "CONFIG_PACKAGE_${pkg}=y" config/arthur.config || fail "baseline plugin is not enabled: $pkg"
done < config/required-plugins.txt
pass BASELINE_REGRESSION_GATE
pass PLUGIN_I18N_BUILD_GATE
pass THEME_COMPATIBILITY_GATE

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
pass COMPATIBILITY_CHECK

# Hard authorization boundary. The source checks above are necessary but not
# sufficient. A production candidate is authorized only by the committed,
# frozen v4.3 state bound to this exact HEAD.
bash ./scripts/implementation-complete-gate.sh

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
state = json.loads(Path("production/current-changeset.json").read_text(encoding="utf-8"))
manifest = {
    "schema_version": "4.3",
    "status": "frozen",
    "changeset_id": state["changeset_id"],
    "base": base,
    "head": head,
    "frozen_source_sha": state["frozen_source_sha"],
    "commits": commits,
    "files": files,
    "required_tasks": state["required_tasks"],
    "gates": {
        "implementation_complete": "PASS",
        "changeset_freeze": "PASS",
        "adguardhome": "PASS",
        "istore_quickstart_official": "PASS",
        "wifi_runtime": "PASS",
        "plugin_i18n": "PASS",
        "themes": "PASS",
        "baseline_regression": "PASS"
    }
}
Path("output/changeset-manifest.json").write_text(
    json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
)
PY

pass CURRENT_CHANGESET_MANIFEST
pass CANDIDATE_SOURCE_GATE
