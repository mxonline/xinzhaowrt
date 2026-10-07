#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
luci_config="$root/files/etc/config/luci"
workflow="$root/.github/workflows/arthur-theme-candidate.yml"

fail() { echo "ARGON_DEFAULT_THEME_GATE: FAIL -- $*" >&2; exit 1; }

[[ -f "$luci_config" ]] || fail 'factory LuCI configuration is missing'
grep -Eq "^[[:space:]]*option mediaurlbase '/luci-static/argon'$" "$luci_config" || fail 'factory mediaurlbase is not Argon'
grep -Fq 'luci-theme-argon' "$workflow" || fail 'Argon is not included in the candidate image'
grep -Fq 'luci-theme-kucat' "$workflow" || fail 'Kucat is not included in the candidate image'
grep -Fq "uci -q set luci.main.mediaurlbase='/luci-static/argon'" "$root/files/etc/uci-defaults/97-xinzhao-luci-defaults" || fail 'first-boot Argon default is missing'
grep -Fq "uci -q set luci.themes.KuCat='/luci-static/kucat'" "$root/files/etc/uci-defaults/97-xinzhao-luci-defaults" || fail 'first-boot KuCat registration is missing'
if rg -n 'mediaurlbase.*(bootstrap|kucat)' "$root/files/etc/uci-defaults" "$root/files/etc/init.d" 2>/dev/null; then
  fail 'a startup script overrides the factory Argon theme'
fi

echo 'ARGON_DEFAULT_THEME_GATE: PASS'
