#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK_FILE="${XINZHAOWRT_SOURCES_LOCK:-$PROJECT_ROOT/config/sources.lock}"
if [[ -f "$LOCK_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$LOCK_FILE"
  set +a
fi

SRC="${1:?Usage: $0 /path/to/immortalwrt}"
cd "$SRC"

SOURCES="$SRC/.xinzhao-sources"
FEED="$SRC/.xinzhao-feed"
mkdir -p "$SOURCES"
rm -rf "$FEED"
mkdir -p "$FEED"

clone_or_update() {
  local name="$1" url="$2" ref="$3"
  local dir="$SOURCES/$name"

  if [[ "$ref" =~ ^[0-9a-fA-F]{40}$ ]]; then
    if [[ ! -d "$dir/.git" ]]; then
      rm -rf "$dir"
      git init "$dir"
      git -C "$dir" remote add origin "$url"
    fi
    git -C "$dir" fetch --depth=1 origin "$ref"
    git -C "$dir" checkout --detach -f FETCH_HEAD
    git -C "$dir" clean -fdx
    return
  fi

  if [[ -d "$dir/.git" ]]; then
    git -C "$dir" fetch --depth=1 origin "$ref"
    git -C "$dir" reset --hard FETCH_HEAD
    git -C "$dir" clean -fdx
  else
    rm -rf "$dir"
    git clone --depth=1 --branch "$ref" "$url" "$dir"
  fi
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
  "${KENZOK8_COMMIT:-master}"
KENZO="$SOURCES/kenzok8-openwrt-packages"

# qualcommax is aarch64/cortex-a53. Keep QuickStart's own architecture metadata;
# do not rewrite it to quickstart.arm.
link_pkg luci-app-istorex "$KENZO/luci-app-istorex"
link_pkg luci-app-lucky "$KENZO/luci-app-lucky/luci-app-lucky"
link_pkg lucky "$KENZO/luci-app-lucky/lucky"
link_pkg luci-app-quickfile "$KENZO/luci-app-quickfile/luci-app-quickfile"
link_pkg quickfile "$KENZO/luci-app-quickfile/quickfile"
link_pkg luci-app-quickstart "$KENZO/luci-app-quickstart"
link_pkg quickstart "$KENZO/quickstart"

# Official iStore feed.
clone_or_update \
  istore \
  https://github.com/linkease/istore.git \
  "${ISTORE_COMMIT:-main}"
ISTORE="$SOURCES/istore"
ISTORE_FEED="$ISTORE/luci"

# Selected ImmortalWrt LuCI applications.
clone_or_update \
  immortalwrt-luci \
  https://github.com/immortalwrt/luci.git \
  "${LUCI_FEED_COMMIT:-master}"
IMMORTAL_LUCI="$SOURCES/immortalwrt-luci"
for pkg in \
  luci-app-adguardhome luci-app-autoreboot luci-app-firewall \
  luci-app-package-manager luci-app-pbr luci-app-samba4 \
  luci-app-smartdns luci-app-sqm luci-app-ttyd luci-app-upnp \
  luci-app-vlmcsd luci-app-wol; do
  link_pkg "$pkg" "$IMMORTAL_LUCI/applications/$pkg"
done

# Selected runtime packages required by the LuCI applications above.
clone_or_update \
  immortalwrt-packages \
  https://github.com/immortalwrt/packages.git \
  "${PACKAGES_FEED_COMMIT:-master}"
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
  "${DISKMAN_COMMIT:-main}"
DISKMAN="$SOURCES/luci-app-diskman"
link_pkg luci-app-diskman "$DISKMAN/luci-app-diskman"

# EasyTier LuCI + EasyTier core.
clone_or_update \
  luci-app-easytier \
  https://github.com/EasyTier/luci-app-easytier.git \
  "${EASYTIER_COMMIT:-main}"
EASYTIER="$SOURCES/luci-app-easytier"
link_pkg luci-app-easytier "$EASYTIER/luci-app-easytier"
link_pkg easytier "$EASYTIER/easytier"

# MosDNS v5 + geodata.
clone_or_update \
  luci-app-mosdns \
  https://github.com/sbwml/luci-app-mosdns.git \
  "${MOSDNS_COMMIT:-v5}"
MOSDNS="$SOURCES/luci-app-mosdns"
link_pkg luci-app-mosdns "$MOSDNS/luci-app-mosdns"
link_pkg mosdns "$MOSDNS/mosdns"

clone_or_update \
  v2ray-geodata \
  https://github.com/sbwml/v2ray-geodata.git \
  "${V2RAY_GEODATA_COMMIT:-master}"
link_pkg v2ray-geodata "$SOURCES/v2ray-geodata"

# OpenClash official package.
clone_or_update \
  OpenClash \
  https://github.com/vernesong/OpenClash.git \
  "${OPENCLASH_COMMIT:-master}"
link_pkg luci-app-openclash "$SOURCES/OpenClash/luci-app-openclash"

# OpenAppFilter: LuCI + userspace + kernel-facing package.
clone_or_update \
  OpenAppFilter \
  https://github.com/destan19/OpenAppFilter.git \
  "${OAF_COMMIT:-master}"
OAF="$SOURCES/OpenAppFilter"
link_pkg luci-app-oaf "$OAF/luci-app-oaf"
link_pkg oaf "$OAF/oaf"
link_pkg open-app-filter "$OAF/open-app-filter"

# Defensive cleanup: iStore's luci-app-store is only installed from the
# dedicated linkease/istore feed, never duplicated in xinzhao.
if [[ -e "$FEED/luci-app-store" ]]; then
  rm -rf "$FEED/luci-app-store"
  echo "REMOVED_DUPLICATE_PACKAGE: luci-app-store from .xinzhao-feed"
fi

if [[ ! -f feeds.conf ]]; then
  cp feeds.conf.default feeds.conf
fi

ensure_official_feed() {
  local name="$1" url="$2"
  if ! grep -Eq "^[[:space:]]*src-(git|git-full|hg)[[:space:]]+$name([[:space:]]|$)" feeds.conf; then
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
  luci-app-mosdns mosdns v2ray-geodata
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
  luci-app-smartdns luci-app-sqm luci-app-ttyd luci-app-upnp luci-app-vlmcsd luci-app-wol

./scripts/feeds install -f -p istore \
  luci-app-store luci-lib-taskd luci-lib-xterm taskd

printf '\nCustom XinZhao feed installed with %d package entries.\n' "${#CUSTOM_PKGS[@]}"
