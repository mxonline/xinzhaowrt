#!/usr/bin/env bash
set -euo pipefail

# Fail-closed control-plane gate. This reads only committed refs and metadata;
# it never builds, flashes, or selects floating/latest dependencies.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG="${BASELINE_TAG:-arthur-known-good-v1}"
EXPECTED_COMMIT="a47d994bbb434dbcfc8036a4acb4379747b65f9f"
EXPECTED_FIRMWARE="XinZhaoWrt-Arthur-fast-33241309046-sysupgrade.bin"
EXPECTED_SHA256="733eeec1375403029f0b08b7307756b2edfd050ca52473891ab340051d3e5612"
EXPECTED_PROJECT_COMMIT="9bc5f471a92048233ff123370830000e124ca32d"
EXPECTED_TOOLCHAIN_RUN="33196164359"

blocked() {
  printf 'PIPELINE BLOCKED: %s\n' "$1" >&2
  exit 1
}

tag_target="$(git -C "$ROOT" rev-parse "refs/tags/$TAG^{commit}" 2>/dev/null)" || blocked "baseline tag $TAG is unavailable"
[[ "$tag_target" == "$EXPECTED_COMMIT" ]] || blocked "tag target is $tag_target, expected $EXPECTED_COMMIT"
printf 'TAG_TARGET=PASS\n'

manifest="$(git -C "$ROOT" show "$TAG:production/arthur-known-good-v1.json" 2>/dev/null)" || blocked 'baseline manifest is unavailable from the frozen tag'
export BASELINE_MANIFEST="$manifest"
python - "$EXPECTED_FIRMWARE" "$EXPECTED_SHA256" "$EXPECTED_PROJECT_COMMIT" "$EXPECTED_TOOLCHAIN_RUN" <<'PY'
import json
import os
import sys

manifest = json.loads(os.environ["BASELINE_MANIFEST"])
expected = {
    "firmware": sys.argv[1],
    "firmware_sha256": sys.argv[2],
    "project_commit": sys.argv[3],
    "toolchain_run": sys.argv[4],
}
for key, value in expected.items():
    if manifest.get(key) != value:
        raise SystemExit(f"{key} mismatch")
if manifest.get("candidate") != "ACCEPTED" or manifest.get("baseline_review") != "PASS":
    raise SystemExit("manifest is not an accepted baseline")
provenance = manifest.get("provenance") or {}
required_provenance = (
    "known_good_lock_sha256",
    "toolchain_acceptance_sha256",
    "toolchain_provenance_sha256",
    "sdk_sha256",
    "imagebuilder_sha256",
    "package_repositories_sha256",
)
if any(not provenance.get(key) for key in required_provenance):
    raise SystemExit("incomplete toolchain provenance")
if "latest" in json.dumps(manifest).lower() or "floating" in json.dumps(manifest).lower():
    raise SystemExit("floating dependency marker")
PY
printf 'MANIFEST=PASS\nFIRMWARE_SHA256=PASS\n'

python - "$ROOT/production/known-good.json" "$ROOT/config/arthur-known-good.lock" <<'PY'
import json
import os
import re
import sys

manifest = json.loads(os.environ["BASELINE_MANIFEST"])
known_good = json.load(open(sys.argv[1], encoding="utf-8"))
if known_good.get("stable_tag") != "arthur-known-good-v1":
    raise SystemExit("main known-good pointer is stale")
if known_good.get("sha256") != manifest["firmware_sha256"]:
    raise SystemExit("main firmware digest is stale")
if known_good.get("lock_sha256") != manifest["provenance"]["known_good_lock_sha256"]:
    raise SystemExit("known-good lock provenance mismatch")
lock_text = open(sys.argv[2], encoding="utf-8").read()
for key, value in manifest.get("feed_refs", {}).items():
    if not re.search(rf'^{re.escape(key)}="{re.escape(value)}"$', lock_text, re.MULTILINE):
        raise SystemExit(f"feed ref mismatch: {key}")
PY
printf 'TOOLCHAIN_PROVENANCE=PASS\n'

python - "$ROOT/config/required-plugins.txt" <<'PY'
import json
import os
import sys

manifest = json.loads(os.environ["BASELINE_MANIFEST"])
with open(sys.argv[1], encoding="utf-8") as handle:
    required = [line.strip() for line in handle if line.strip() and not line.startswith("#")]
if len(required) != 22 or manifest.get("plugins_required") != required or manifest.get("plugins_verified") != 22:
    raise SystemExit("required plugin baseline mismatch")
PY
printf 'PLUGINS_22=PASS\nBASELINE_INTEGRITY=PASS\n'
