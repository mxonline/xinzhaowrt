#!/usr/bin/env bash
set -euo pipefail

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
# The exact luci-app-istore package does not exist; the package names are
# luci-app-istorex (Kenzok8 extension) and luci-app-store (official iStore).
clone_or_update \
  kenzok8-openwrt-packages \
  https://github.com/kenzok8/openwrt-packages.git \
  master
KENZO="$SOURCES/kenzok8-openwrt-packages"
link_pkg luci-app-istorex "$KENZO/luci-app-istorex"
link_pkg luci-app-lucky "$KENZO/luci-app-lucky/luci-app-lucky"
link_pkg lucky "$KENZO/luci-app-lucky/lucky"
link_pkg luci-app-quickfile "$KENZO/luci-app-quickfile/luci-app-quickfile"
link_pkg quickfile "$KENZO/luci-app-quickfile/quickfile"
link_pkg luci-app-quickstart "$KENZO/luci-app-quickstart"
link_pkg quickstart "$KENZO/quickstart"

# Official iStore feed. Keep store/taskd together so luci-app-store uses the
# upstream source instead of a mirror with ambiguous package provenance.
clone_or_update \
  istore \
  https://github.com/linkease/istore.git \
  main
ISTORE="$SOURCES/istore"
ISTORE_FEED="$ISTORE/luci"

# DiskMan.
clone_or_update \
  luci-app-diskman \
  https://github.com/sbwml/luci-app-diskman.git \
  main
DISKMAN="$SOURCES/luci-app-diskman"
link_pkg luci-app-diskman "$DISKMAN/luci-app-diskman"

# EasyTier LuCI + EasyTier core.
clone_or_update \
  luci-app-easytier \
  https://github.com/EasyTier/luci-app-easytier.git \
  main
EASYTIER="$SOURCES/luci-app-easytier"
link_pkg luci-app-easytier "$EASYTIER/luci-app-easytier"
link_pkg easytier "$EASYTIER/easytier"

# MosDNS v5 + v2dat + geodata.
clone_or_update \
  luci-app-mosdns \
  https://github.com/sbwml/luci-app-mosdns.git \
  v5
MOSDNS="$SOURCES/luci-app-mosdns"
link_pkg luci-app-mosdns "$MOSDNS/luci-app-mosdns"
link_pkg mosdns "$MOSDNS/mosdns"
link_pkg v2dat "$MOSDNS/v2dat"

clone_or_update \
  v2ray-geodata \
  https://github.com/sbwml/v2ray-geodata.git \
  master
link_pkg v2ray-geodata "$SOURCES/v2ray-geodata"

# OpenClash official package.
clone_or_update \
  OpenClash \
  https://github.com/vernesong/OpenClash.git \
  master
link_pkg luci-app-openclash "$SOURCES/OpenClash/luci-app-openclash"

# OpenAppFilter: LuCI + userspace + kernel-facing package.
clone_or_update \
  OpenAppFilter \
  https://github.com/destan19/OpenAppFilter.git \
  master
OAF="$SOURCES/OpenAppFilter"
link_pkg luci-app-oaf "$OAF/luci-app-oaf"
link_pkg oaf "$OAF/oaf"
link_pkg open-app-filter "$OAF/open-app-filter"

# Register the assembled local feed.  Using a feed keeps package layout
# compatible with OpenWrt's normal package/feeds/<feed>/<package> structure.
if [[ ! -f feeds.conf ]]; then
  cp feeds.conf.default feeds.conf
fi
sed -i '/^[[:space:]]*src-link[[:space:]]\+istore[[:space:]]/d' feeds.conf
sed -i '/^[[:space:]]*src-link[[:space:]]\+xinzhao[[:space:]]/d' feeds.conf
printf 'src-link istore %s\n' "$ISTORE_FEED" >> feeds.conf
printf 'src-link xinzhao %s\n' "$FEED" >> feeds.conf

./scripts/feeds update istore
./scripts/feeds update xinzhao

# Install all official iStore packages after both feed indexes exist.  The
# second forced pass prevents dependency ordering from hiding package names.
for pkg in luci-app-store luci-lib-taskd luci-lib-xterm taskd; do
  ./scripts/feeds uninstall "$pkg" >/dev/null 2>&1 || true
  ./scripts/feeds install -f -p istore "$pkg"
done

# Replace any same-named package installed from another feed with our selected
# source.  This avoids duplicate package definitions from broad feeds.
CUSTOM_PKGS=(
  luci-app-istorex luci-app-lucky lucky
  luci-app-quickfile quickfile luci-app-quickstart quickstart
  luci-app-diskman luci-app-easytier easytier
  luci-app-mosdns mosdns v2dat v2ray-geodata
  luci-app-openclash luci-app-oaf oaf open-app-filter
)

for pkg in "${CUSTOM_PKGS[@]}"; do
  ./scripts/feeds uninstall "$pkg" >/dev/null 2>&1 || true
  ./scripts/feeds install -f -p xinzhao "$pkg"
done

# Reinstall the two dependency chains after every selected package is known.
./scripts/feeds install -f -p istore luci-app-store luci-lib-taskd luci-lib-xterm taskd
./scripts/feeds install -f -p xinzhao luci-app-istorex luci-app-quickstart quickstart

printf '\nCustom XinZhao feed installed with %d package entries.\n' "${#CUSTOM_PKGS[@]}"
