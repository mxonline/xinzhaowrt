#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CFG="${1:-.config}"
REQUIRED_FILE="$PROJECT_ROOT/config/required-plugins.txt"

missing=0
while IFS= read -r pkg; do
  [[ -z "$pkg" || "$pkg" == \#* ]] && continue
  sym="CONFIG_PACKAGE_${pkg}=y"
  if ! grep -qxF "$sym" "$CFG"; then
    echo "MISSING: $sym"
    missing=1
  fi
done < "$REQUIRED_FILE"

if (( missing )); then
  echo
  echo "One or more mandatory packages did not survive make defconfig."
  echo "Do not delete a requested plugin to make the build pass; fix its source/dependencies instead."
  exit 1
fi

echo "PASS: all mandatory LuCI package symbols are enabled."
