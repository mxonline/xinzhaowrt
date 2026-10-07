#!/usr/bin/env bash
set -euo pipefail

MAKEFILE="${1:?Usage: $0 /path/to/linkease-common-bin/Makefile}"
TARGET='$(1)/etc/uci-defaults/linkease-fw'

[[ -f "$MAKEFILE" ]] || {
  echo "ERROR: LinkEase common binary Makefile is missing: $MAKEFILE" >&2
  exit 1
}

matches="$(grep -Fc "$TARGET" "$MAKEFILE" || true)"
[[ "$matches" == 1 ]] || {
  echo "ERROR: expected exactly one LinkEase WAN firewall UCI-default install target in $MAKEFILE; found $matches" >&2
  exit 1
}
grep -F "$TARGET" "$MAKEFILE" | grep -Fq '$(INSTALL_BIN)' || {
  echo "ERROR: LinkEase WAN firewall target is not the expected install payload in $MAKEFILE" >&2
  exit 1
}

temporary="$(mktemp "${MAKEFILE}.safe.XXXXXX")"
trap 'rm -f "$temporary"' EXIT
awk -v target="$TARGET" 'index($0, target) { next } { print }' "$MAKEFILE" > "$temporary"
mv "$temporary" "$MAKEFILE"
trap - EXIT

if grep -Fq "$TARGET" "$MAKEFILE"; then
  echo "ERROR: LinkEase WAN firewall UCI-default remains in $MAKEFILE" >&2
  exit 1
fi

echo 'LINKEASE_WAN_FIREWALL_UCI_DEFAULT_REMOVED=YES'
