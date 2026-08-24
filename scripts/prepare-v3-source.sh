#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK_FILE="${XINZHAOWRT_SOURCES_LOCK:-$PROJECT_ROOT/config/sources.lock}"
WORKDIR="${1:-$PROJECT_ROOT/work/v3}"
SRC="$WORKDIR/immortalwrt"

[[ -f "$LOCK_FILE" ]] || { echo "ERROR: sources lock missing: $LOCK_FILE" >&2; exit 1; }
set -a
# shellcheck disable=SC1090
source "$LOCK_FILE"
set +a

[[ "${IMMORTALWRT_COMMIT:-}" =~ ^[0-9a-f]{40}$ ]] || {
  echo "ERROR: IMMORTALWRT_COMMIT is not a locked SHA" >&2
  exit 1
}

rm -rf "$SRC"
mkdir -p "$WORKDIR"
git init "$SRC"
git -C "$SRC" remote add origin https://github.com/VIKINGYFY/immortalwrt.git
git -C "$SRC" fetch --depth=1 origin "$IMMORTALWRT_COMMIT"
git -C "$SRC" checkout --detach -f FETCH_HEAD

"$PROJECT_ROOT/scripts/apply-sources-lock.sh" "$SRC"

cd "$SRC"
./scripts/feeds update -a
./scripts/feeds install -a

"$PROJECT_ROOT/scripts/add-custom-packages.sh" "$SRC"
./scripts/feeds update -a
./scripts/feeds install -a

cp "$PROJECT_ROOT/config/arthur.config" .config
make defconfig
"$PROJECT_ROOT/scripts/check-config.sh" .config
"$PROJECT_ROOT/scripts/verify-source-locks.sh" "$SRC"

echo "V3_SOURCE_READY=$SRC"
