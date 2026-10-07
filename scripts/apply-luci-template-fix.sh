#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:?usage: $0 <immortalwrt-source-dir>}"
LUCI="$SRC/feeds/luci"
PATCH="$PROJECT_ROOT/patches/luci/0001-template-parser-escape-crlf.patch"
TARGET="modules/luci-lua-runtime/src/template_utils.c"

[[ -d "$LUCI/.git" ]] || { echo "ERROR: LuCI feed is missing: $LUCI" >&2; exit 1; }
[[ -s "$PATCH" ]] || { echo "ERROR: LuCI parser patch is missing: $PATCH" >&2; exit 1; }

if git -C "$LUCI" apply --check "$PATCH" >/dev/null 2>&1; then
  git -C "$LUCI" apply "$PATCH"
  echo "LUCI_TEMPLATE_FIX=APPLIED target=$TARGET"
elif git -C "$LUCI" apply --reverse --check "$PATCH" >/dev/null 2>&1; then
  echo "LUCI_TEMPLATE_FIX=ALREADY_APPLIED target=$TARGET"
else
  echo "ERROR: LuCI parser patch neither applies nor is already applied: $PATCH" >&2
  git -C "$LUCI" diff -- "$TARGET" >&2 || true
  exit 1
fi
