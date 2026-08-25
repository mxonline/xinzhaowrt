#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:?Usage: $0 /path/to/immortalwrt}"
cd "$SRC"

LOCK_FILE="${KNOWN_GOOD_LOCK:-$PROJECT_ROOT/config/arthur-known-good.lock}"
if [[ -f "$LOCK_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$LOCK_FILE"
  echo "KNOWN_GOOD_LOCK: $LOCK_FILE"
fi

SOURCES="$SRC/.xinzhao-sources"
FEED="$SRC/.xinzhao-feed"
mkdir -p "$SOURCES"
rm -rf "$FEED"
mkdir -p "$FEED"

clone_or_update() {
  local name="$1" url="$2" ref="$3"
  local dir="$SOURCES/$name"
  if [[ -d "$dir/.git" ]]; then
    git -C "$dir" fetch --depth=1 origin "$ref"
    git -C "$dir" reset --hard FETCH_HEAD
    git -C "$dir" clean -fdx
  else
    rm -rf "$dir"
    git clone --filter=blob:none --no-checkout "$url" "$dir"
    git -C "$dir" fetch --depth=1 origin "$ref"
    git -C "$dir" -c advice.detachedHead=false checkout --detach FETCH_HEAD
  fi
  local actual
  actual="$(git -C "$dir" rev-parse HEAD)"
  echo "PINNED_SOURCE: $name=$actual"
}

link_pkg() {
  local pkg="$1" src="$2"
  [[ -f "$src/Makefile" ]] || {
    echo "ERROR: package source for $pkg has no Makefile: $src"
    exit 1
  }
  ln -s "$src" "$FEED/$pkg"
}

# iStoreX/QuickStart ecosystem + Lucky + QuickFile.
clone_or_update \
  kenzok8-openwrt-packages \
  https://github.com/kenzok8/openwrt-packages.git \
  "${KENZOK8_REF:-master}"
KENZO="$SOURCES/kenzok8-openwrt-packages"

# 京东云亚瑟 IPQ60xx 的 OpenWrt 架构名为 arm_cortex-a7，而 quickstart
# 上游发布的是通用 arm 二进制。仅修正临时自定义 feed 的元数据，不修改
# config/arthur.config 或 config/required-plugins.txt。
QUICKSTART_MAKEFILE="$KENZO/quickstart/Makefile"
if grep -q 'PKG_ARCH_quickstart:=$(ARCH)' "$QUICKSTART_MAKEFILE" && \
   grep -q 'DEPENDS:=@(x86_64||aarch64||arm)' "$QUICKSTART_MAKEFILE"; then
  sed -i \
    -e 's/DEPENDS:=@(x86_64||aarch64||arm) /DEPENDS:=/' \
    -e 's/quickstart\.\$(PKG_ARCH_quickstart)/quickstart.arm/' \
    "$QUICKSTART_MAKEFILE"
  echo 'PATCHED_PACKAGE_ARCH: quickstart keeps target package arch and installs generic arm binary'
else
  echo 'ERROR: quickstart Makefile 的预期架构声明已变化，拒绝静默应用兼容性补丁。' >&2
  exit 1
fi

link_pkg luci-app-istorex "$KENZO/luci-app-istorex"
link_pkg luci-app-lucky "$KENZO/luci-app-lucky/luci-app-lucky"
link_pkg lucky "$KENZO/luci-app-lucky/lucky"
link_pkg luci-app-quickfile "$KENZO/luci-app-quickfile/luci-app-quickfile"
link_pkg quickfile "$KENZO/luci-app-quickfile/quickfile"
link_pkg luci-app-quickstart "$KENZO/luci-app-quickstart"
link_pkg quickstart "$KENZO/quickstart"

# 官方 iStore feed。
clone_or_update \
  istore \
  https://github.com/linkease/istore.git \
  "${ISTORE_REF:-main}"
ISTORE="$SOURCES/istore"
ISTORE_FEED="$ISTORE/luci"

# ImmortalWrt LuCI applications.
clone_or_update \
  immortalwrt-luci \
  https://github.com/immortalwrt/luci.git \
  "${LUCI_REF:-master}"
IMMORTAL_LUCI="$SOURCES/immortalwrt-luci"
for pkg in \
  luci-app-adguardhome luci-app-autoreboot luci-app-firewall \
  luci-app-package-manager luci-app-pbr luci-app-samba4 \
  luci-app-smartdns luci-app-sqm luci-app-ttyd luci-app-upnp \
  luci-app-vlmcsd luci-app-wol; do
  link_pkg "$pkg" "$IMMORTAL_LUCI/applications/$pkg"
done

# ImmortalWrt packages runtime dependencies.
clone_or_update \
  immortalwrt-packages \
  https://github.com/immortalwrt/packages.git \
  "${PACKAGES_REF:-master}"
IMMORTAL_PACKAGES="$SOURCES/immortalwrt-packages"
for pkg_path in \
  "smartdns:net/smartdns" \
  "sqm-scripts:net/sqm-scripts" \
  "ttyd:utils/ttyd" \
  "miniupnpd:net/miniupnpd" \
  "vlmcsd:net/vlmcsd" \
  "etherwake:net/etherwake" \
  "adguardhome:net/adguardhome" \
  "pbr:net/pbr" \
  "samba4:net/samba4"; do
  pkg="${pkg_path%%:*}"
  path="${pkg_path#*:}"
  link_pkg "$pkg" "$IMMORTAL_PACKAGES/$path"
done

# DiskMan.
clone_or_update \
  luci-app-diskman \
  https://github.com/sbwml/luci-app-diskman.git \
  "${DISKMAN_REF:-main}"
DISKMAN="$SOURCES/luci-app-diskman"
link_pkg luci-app-diskman "$DISKMAN/luci-app-diskman"

# EasyTier LuCI + core.
clone_or_update \
  luci-app-easytier \
  https://github.com/EasyTier/luci-app-easytier.git \
  "${EASYTIER_REF:-main}"
EASYTIER="$SOURCES/luci-app-easytier"
link_pkg luci-app-easytier "$EASYTIER/luci-app-easytier"
link_pkg easytier "$EASYTIER/easytier"

# MosDNS v5. The selected revision includes geo2txt as a required dependency.
clone_or_update \
  luci-app-mosdns \
  https://github.com/sbwml/luci-app-mosdns.git \
  "${MOSDNS_REF:-v5}"
MOSDNS="$SOURCES/luci-app-mosdns"
link_pkg luci-app-mosdns "$MOSDNS/luci-app-mosdns"
link_pkg mosdns "$MOSDNS/mosdns"
link_pkg geo2txt "$MOSDNS/geo2txt"

clone_or_update \
  v2ray-geodata \
  https://github.com/sbwml/v2ray-geodata.git \
  "${V2RAY_GEODATA_REF:-master}"
link_pkg v2ray-geodata "$SOURCES/v2ray-geodata"

# OpenClash official package.
clone_or_update \
  OpenClash \
  https://github.com/vernesong/OpenClash.git \
  "${OPENCLASH_REF:-master}"
link_pkg luci-app-openclash "$SOURCES/OpenClash/luci-app-openclash"

# OpenAppFilter: LuCI + userspace + kernel-facing package.
clone_or_update \
  OpenAppFilter \
  https://github.com/destan19/OpenAppFilter.git \
  "${OPENAPPFILTER_REF:-master}"
OAF="$SOURCES/OpenAppFilter"
link_pkg luci-app-oaf "$OAF/luci-app-oaf"
link_pkg oaf "$OAF/oaf"
link_pkg open-app-filter "$OAF/open-app-filter"

if [[ -e "$FEED/luci-app-store" ]]; then
  rm -rf "$FEED/luci-app-store"
  echo "REMOVED_DUPLICATE_PACKAGE: luci-app-store from .xinzhao-feed"
fi

if [[ ! -f feeds.conf ]]; then
  cp feeds.conf.default feeds.conf
fi

ensure_official_feed() {
  local name="$1" url="$2"
  if ! grep -Eq "^[[:space:]]*src-(git|hg)[[:space:]]+$name([[:space:]]|$)" feeds.conf; then
    printf 'src-git %s %s\n' "$name" "$url" >> feeds.conf
    echo "ADDED_OFFICIAL_FEED: $name -> $url"
  else
    echo "FOUND_OFFICIAL_FEED: $name"
  fi
}
ensure_official_feed packages https://github.com/immortalwrt/packages.git
ensure_official_feed luci https://github.com/immortalwrt/luci.git
ensure_official_feed routing https://github.com/openwrt/routing.git
sed -i '/^[[:space:]]*src-link[[:space:]]\+xinzhao[[:space:]]/d' feeds.conf
sed -i '/^[[:space:]]*src-link[[:space:]]\+istore[[:space:]]/d' feeds.conf
printf 'src-link istore %s\n' "$ISTORE_FEED" >> feeds.conf
printf 'src-link xinzhao %s\n' "$FEED" >> feeds.conf

./scripts/feeds update packages luci routing
./scripts/feeds install -a
./scripts/feeds update istore
./scripts/feeds update xinzhao

CUSTOM_PKGS=(
  luci-app-istorex luci-app-lucky lucky
  luci-app-quickfile quickfile luci-app-quickstart quickstart
  luci-app-adguardhome luci-app-autoreboot luci-app-firewall
  luci-app-package-manager luci-app-pbr luci-app-samba4
  luci-app-smartdns luci-app-sqm luci-app-ttyd luci-app-upnp luci-app-vlmcsd luci-app-wol
  smartdns sqm-scripts ttyd miniupnpd vlmcsd etherwake adguardhome pbr samba4
  luci-app-diskman luci-app-easytier easytier
  luci-app-mosdns mosdns geo2txt v2ray-geodata
  luci-app-openclash luci-app-oaf oaf open-app-filter
)

for pkg in "${CUSTOM_PKGS[@]}"; do
  ./scripts/feeds uninstall "$pkg" >/dev/null 2>&1 || true
  ./scripts/feeds install -f -p xinzhao "$pkg"
done

./scripts/feeds install -f -p xinzhao \
  luci-app-istorex luci-app-quickstart quickstart \
  luci-app-adguardhome luci-app-autoreboot luci-app-firewall \
  luci-app-package-manager luci-app-pbr luci-app-samba4 \
  luci-app-smartdns luci-app-sqm luci-app-ttyd luci-app-upnp luci-app-vlmcsd luci-app-wol \
  luci-app-mosdns mosdns geo2txt

./scripts/feeds install -f -p istore \
  luci-app-store luci-lib-taskd luci-lib-xterm taskd

printf '\nCustom XinZhao feed installed with %d package entries.\n' "${#CUSTOM_PKGS[@]}"
