#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCHER="$ROOT/scripts/remove-linkease-wan-firewall-default.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "LINKEASE_SAFE_PAYLOAD: FAIL -- $*" >&2
  exit 1
}

cat > "$TMP/Makefile" <<'EOF'
define Package/install
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/linkease-fw $(1)/etc/uci-defaults/linkease-fw
	$(INSTALL_BIN) ./files/linkease $(1)/etc/uci-defaults/linkease
endef
EOF

"$PATCHER" "$TMP/Makefile" || fail 'the locked firewall install target was not safely removed'
if grep -Fq '/etc/uci-defaults/linkease-fw' "$TMP/Makefile"; then
  fail 'the WAN 8897 UCI-default install target remains in the package payload'
fi
grep -Fq '$(1)/etc/uci-defaults/linkease' "$TMP/Makefile" || fail 'the non-firewall LinkEase default was removed too'

cat > "$TMP/Makefile.missing" <<'EOF'
define Package/install
	$(INSTALL_BIN) ./files/linkease $(1)/etc/uci-defaults/linkease
endef
EOF
if "$PATCHER" "$TMP/Makefile.missing" >/dev/null 2>&1; then
  fail 'the source patch silently succeeded after the upstream target disappeared'
fi

echo 'LINKEASE_SAFE_PAYLOAD=PASS'
