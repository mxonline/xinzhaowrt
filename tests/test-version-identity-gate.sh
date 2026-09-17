#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

PYTHON_BIN="${PYTHON_BIN:-python3}"
if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  PYTHON_BIN=python
fi
command -v "$PYTHON_BIN" >/dev/null 2>&1 || fail "Python interpreter not found"
VERSION="$(tr -d '\r\n ' < "$ROOT/VERSION")"
TARGET_RELEASE="${TARGET_RELEASE:-v0.1.5}"
TARGET_VERSION="${TARGET_RELEASE#v}"

[[ "$TARGET_RELEASE" == v[0-9]* ]] || fail "invalid target release: $TARGET_RELEASE"
[[ "$TARGET_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "invalid target version: $TARGET_VERSION"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "invalid VERSION: $VERSION"

CURRENT_STABLE="$("$PYTHON_BIN" - "$ROOT/production/resume-state.json" <<'PY'
import json
import pathlib
import sys

state = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
stable = state.get("accepted_release") or state.get("production", {}).get("release")
if not isinstance(stable, str) or not stable.startswith("v"):
    raise SystemExit("missing accepted stable release")
print(stable)
PY
)"
CURRENT_STABLE_VERSION="${CURRENT_STABLE#v}"

"$PYTHON_BIN" - "$CURRENT_STABLE_VERSION" "$TARGET_VERSION" <<'PY'
import sys

def parse(value):
    parts = value.split(".")
    if len(parts) != 3 or not all(part.isdigit() for part in parts):
        raise SystemExit(f"invalid semantic version: {value}")
    return tuple(int(part) for part in parts)

if parse(sys.argv[2]) <= parse(sys.argv[1]):
    raise SystemExit("target version must be greater than current stable")
PY

[[ "$VERSION" == "$TARGET_VERSION" ]] || fail "VERSION does not match target release"

if git -C "$ROOT" show-ref --verify --quiet "refs/tags/$TARGET_RELEASE"; then
  fail "target tag already exists locally: $TARGET_RELEASE"
fi

STATE_RELEASES="$("$PYTHON_BIN" - "$ROOT/production/resume-state.json" <<'PY'
import json
import pathlib
import sys

state = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
values = [state.get("accepted_release"), state.get("release"), state.get("production", {}).get("release")]
print("\n".join(value for value in values if isinstance(value, str)))
PY
)"
if grep -Fxq "$TARGET_RELEASE" <<<"$STATE_RELEASES"; then
  fail "target release is already recorded in resume-state"
fi

CONFIG_VERSION="$(sed -nE 's/^CONFIG_VERSION_NUMBER="([^"]+)"$/\1/p' "$ROOT/config/arthur.config")"
[[ "$CONFIG_VERSION" == "$VERSION" ]] || fail "config/arthur.config CONFIG_VERSION_NUMBER diverges from VERSION"

grep -Fq 'source "$PROJECT_ROOT/build.env"' "$ROOT/scripts/build.sh" || fail 'build.sh must load project defaults before version resolution'
grep -Fq 'FIRMWARE_VERSION="$(tr -d' "$ROOT/scripts/build.sh" || fail 'build.sh must source VERSION for firmware metadata'
"$PYTHON_BIN" - "$ROOT/scripts/build.sh" <<'PY'
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
source = text.find('source "$PROJECT_ROOT/build.env"')
override = text.find('FIRMWARE_VERSION="$(tr -d')
if source < 0 or override < 0 or source > override:
    raise SystemExit("build.sh must override build.env version with VERSION")
PY
grep -Fq 'BASE_VERSION="$(tr -d' "$ROOT/scripts/release-candidate.sh" || fail 'release-candidate.sh must source VERSION for release tags'

for file in "$ROOT/VERSION" "$ROOT/config/arthur.config"; do
  grep -Fq '0.1.3' "$file" && fail "active version source still contains retired 0.1.3: $file"
done

echo "CURRENT_STABLE=$CURRENT_STABLE"
echo "TARGET_RELEASE=$TARGET_RELEASE"
echo "TARGET_VERSION=$TARGET_VERSION"
VERSION_BEFORE_AUDIT="unknown"
cursor="$(git -C "$ROOT" rev-parse HEAD^ 2>/dev/null || true)"
while [[ -n "$cursor" ]]; do
  candidate="$(git -C "$ROOT" show "$cursor:VERSION" 2>/dev/null | tr -d '\r\n ' || true)"
  if [[ -n "$candidate" && "$candidate" != "$VERSION" ]]; then
    VERSION_BEFORE_AUDIT="$candidate"
    break
  fi
  cursor="$(git -C "$ROOT" rev-parse "$cursor^" 2>/dev/null || true)"
done
echo "VERSION_BEFORE_AUDIT=$VERSION_BEFORE_AUDIT"
echo "VERSION_AFTER=$VERSION"
echo "VERSION_GT_CURRENT_STABLE=PASS"
echo "VERSION_MATCH_TARGET_RELEASE=PASS"
echo "VERSION_NOT_ALREADY_RELEASED=PASS"
echo "TAG_v0.1.5_AVAILABLE=PASS"
echo "ARTIFACT_VERSION_SOURCE_SINGLE=PASS"
echo "BUILD_ENV_VERSION_OVERRIDE=PASS"
echo "NO_VERSION_REGRESSION=PASS"
echo "VERSION_IDENTITY_GATE=PASS"
