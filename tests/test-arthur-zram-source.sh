#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$ROOT/config/arthur.config"
DEFAULTS="$ROOT/files/etc/uci-defaults/98-xinzhao-zram-defaults"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

grep -Fqx 'CONFIG_PACKAGE_kmod-zram=y' "$CONFIG" || fail 'kmod-zram is not selected'
grep -Fqx 'CONFIG_PACKAGE_zram-swap=y' "$CONFIG" || fail 'zram-swap is not selected'
grep -Fqx 'CONFIG_KERNEL_ZRAM_BACKEND_LZ4=y' "$CONFIG" || fail 'ZRAM LZ4 backend is not selected'
grep -Fqx 'CONFIG_KERNEL_ZRAM_DEF_COMP_LZ4=y' "$CONFIG" || fail 'ZRAM default compressor is not selected as LZ4'
grep -Fqx 'CONFIG_TARGET_qualcommax_ipq60xx_DEVICE_jdcloud_re-ss-01=y' "$CONFIG" || fail 'Arthur target profile changed'

[[ -s "$DEFAULTS" ]] || fail 'ZRAM defaults overlay is missing'
grep -Fqx "uci -q set system.@system[0].zram_size_mb='192'" "$DEFAULTS" || fail 'ZRAM size default is not fixed at 192 MiB'
grep -Fqx "uci -q set system.@system[0].zram_comp_algo='lz4'" "$DEFAULTS" || fail 'ZRAM compressor default is not fixed at lz4'

if grep -vE '^[[:space:]]*#' "$DEFAULTS" | rg -n -i 'swapfile|dd[[:space:]].*(swap|/tmp)|mkswap[[:space:]]+[^/]*(/tmp|/overlay|/root)'; then
  fail 'ZRAM defaults overlay creates or flashes a swapfile'
fi

echo 'ARTHUR_ZRAM_SOURCE=PASS'
