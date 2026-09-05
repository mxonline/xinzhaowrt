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
QUICKSTART_LOCK_FILE="${ISTORE_QUICKSTART_LOCK:-$PROJECT_ROOT/config/istore-quickstart.lock}"
if [[ -f "$QUICKSTART_LOCK_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$QUICKSTART_LOCK_FILE"
  echo "ISTORE_QUICKSTART_LOCK: $QUICKSTART_LOCK_FILE"
fi
THEME_LOCK_FILE="${ARTHUR_THEME_LOCK:-$PROJECT_ROOT/config/arthur-theme.lock}"
[[ -f "$THEME_LOCK_FILE" ]] || { echo "ERROR: Arthur theme lock missing: $THEME_LOCK_FILE" >&2; exit 1; }
# shellcheck disable=SC1090
source "$THEME_LOCK_FILE"
: "${ARGON_REF:?ARGON_REF is required}"
: "${KUCAT_REF:?KUCAT_REF is required}"
echo "ARTHUR_THEME_LOCK: $THEME_LOCK_FILE"

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

# Frozen themes are production inputs. Apply the same accepted transformations
# that passed Arthur Theme Candidate 33790155987 before exposing them to feeds.
clone_or_update \
  luci-theme-argon \
  https://github.com/jerrykuku/luci-theme-argon.git \
  "$ARGON_REF"
clone_or_update \
  luci-theme-kucat \
  https://github.com/sirpdboy/luci-theme-kucat.git \
  "$KUCAT_REF"
ARGON="$SOURCES/luci-theme-argon"
KUCAT="$SOURCES/luci-theme-kucat"
rm -f \
  "$KUCAT/root/etc/uci-defaults/30_luci-kuacat" \
  "$KUCAT/root/etc/uci-defaults/30_luci-kucat" \
  "$KUCAT/root/usr/libexec/rpcd/luci.kucatget" \
  "$KUCAT/root/usr/share/rpcd/acl.d/luci-app-kucat-config.json"
sed -i '/^LUCI_DEPENDS:=+wget +curl +jsonfilter$/d' "$KUCAT/Makefile"
for theme_dir in "$ARGON" "$KUCAT"; do
  while IFS= read -r -d '' template; do
    sed -i \
      -e 's#/luci-static/argon/favicon.ico#/luci-static/xinzhao/favicon.ico#g' \
      -e 's#/luci-static/argon/icon/favicon-32x32.png#/luci-static/xinzhao/favicon-32x32.png#g' \
      -e 's#/luci-static/argon/icon/android-icon-192x192.png#/luci-static/xinzhao/favicon-192x192.png#g' \
      -e 's#/luci-static/argon/icon/apple-icon-[0-9]*x[0-9]*.png#/luci-static/xinzhao/apple-touch-icon.png#g' \
      -e 's#/luci-static/argon/img/argon.svg#/luci-static/xinzhao/logo.png#g' \
      -e 's#/luci-static/kucat/logo.svg#/luci-static/xinzhao/logo.png#g' \
      -e 's#{{ media }}/favicon.ico#/luci-static/xinzhao/favicon.ico#g' \
      -e 's#{{ media }}/icon/favicon-[0-9]*x[0-9]*.png#/luci-static/xinzhao/favicon-32x32.png#g' \
      -e 's#{{ media }}/icon/android-icon-192x192.png#/luci-static/xinzhao/favicon-192x192.png#g' \
      -e 's#{{ media }}/icon/apple-icon-[0-9]*x[0-9]*.png#/luci-static/xinzhao/apple-touch-icon.png#g' \
      -e 's#{{ media }}/icon/ms-icon-144x144.png#/luci-static/xinzhao/favicon-192x192.png#g' \
      -e 's#{{ media }}/logo.png#/luci-static/xinzhao/logo.png#g' \
      -e 's#{{ media }}/img/logo[0-9]*.png#/luci-static/xinzhao/logo.png#g' \
      -e "s#const hostname = striptags(boardinfo?.hostname ?? '?');#const hostname = 'XinZhaoWrt';#g" \
      -e 's#{{ media }}/img/logo180.png#/luci-static/xinzhao/logo.png#g' \
      -e 's#{{ media }}/img/logo150.png#/luci-static/xinzhao/logo.png#g' \
      -e 's|<a class="brand" href="#">{{ hostname }}</a>|<a class="brand" href="#"><img class="xz-brand-logo" src="/luci-static/xinzhao/logo.png" alt="XinZhaoWrt"><span class="xz-brand-label">XinZhaoWrt</span></a>|g' \
      -e 's#ImmortalWRT - LuCI#XinZhaoWrt#g' \
      -e 's#ImmortalWRT#XinZhaoWrt#g' \
      -e 's#</head>#<script src="/luci-static/xinzhao/branding.js"></script></head>#g' \
      "$template"
  done < <(find "$theme_dir" -type f \( -name '*.htm' -o -name '*.html' -o -name '*.ut' \) -print0)
done
link_pkg luci-theme-argon "$ARGON"
link_pkg luci-theme-kucat "$KUCAT"

# iStoreX ecosystem + Lucky + QuickFile. QuickStart itself is sourced from
# the official iStoreOS LinkEase repositories below.
clone_or_update \
  kenzok8-openwrt-packages \
  https://github.com/kenzok8/openwrt-packages.git \
  "${KENZOK8_REF:-master}"
KENZO="$SOURCES/kenzok8-openwrt-packages"

# AdGuard Home is intentionally isolated from the broader kenzok8 source
# family. Its complete mature CBI manager is fixed at the accepted revision.
: "${ADGUARD_MATURE_REF:?ADGUARD_MATURE_REF is required}"
clone_or_update \
  kenzok8-adguardhome \
  https://github.com/kenzok8/openwrt-packages.git \
  "$ADGUARD_MATURE_REF"
ADGUARD_MATURE="$SOURCES/kenzok8-adguardhome"

link_pkg luci-app-istorex "$KENZO/luci-app-istorex"
link_pkg luci-app-lucky "$KENZO/luci-app-lucky/luci-app-lucky"
link_pkg lucky "$KENZO/luci-app-lucky/lucky"
link_pkg luci-app-quickfile "$KENZO/luci-app-quickfile/luci-app-quickfile"
link_pkg quickfile "$KENZO/luci-app-quickfile/quickfile"
link_pkg luci-app-adguardhome "$ADGUARD_MATURE/luci-app-adguardhome"
# iStoreOS Original QuickStart: keep frontend/RPC/backend/service sources
# paired at fixed, auditable upstream revisions.
clone_or_update \
  istoreos-luci \
  "${ISTORE_QUICKSTART_LUCI_REPO:-https://github.com/linkease/nas-packages-luci.git}" \
  "${ISTORE_QUICKSTART_LUCI_REF:?ISTORE_QUICKSTART_LUCI_REF is required}"
clone_or_update \
  istoreos-packages \
  "${ISTORE_QUICKSTART_REPO:-https://github.com/linkease/nas-packages.git}" \
  "${ISTORE_QUICKSTART_REF:?ISTORE_QUICKSTART_REF is required}"
ISTOREOS_LUCI="$SOURCES/istoreos-luci"
ISTOREOS_PACKAGES="$SOURCES/istoreos-packages"
QUICKSTART_MAKEFILE="$ISTOREOS_PACKAGES/network/services/quickstart/Makefile"
grep -q 'PKG_ARCH_quickstart:=$(ARCH)' "$QUICKSTART_MAKEFILE" || {
  echo 'ERROR: official QuickStart must select the target architecture artifact.' >&2
  exit 1
}
grep -Fq 'quickstart.$(PKG_ARCH_quickstart)' "$QUICKSTART_MAKEFILE" || {
  echo 'ERROR: official QuickStart artifact selector is missing.' >&2
  exit 1
}
link_pkg luci-app-quickstart "$ISTOREOS_LUCI/luci/luci-app-quickstart"
link_pkg quickstart "$ISTOREOS_PACKAGES/network/services/quickstart"

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
  luci-app-autoreboot luci-app-firewall \
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
  luci-theme-argon luci-theme-kucat
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
  luci-theme-argon luci-theme-kucat \
  luci-app-istorex luci-app-quickstart quickstart \
  luci-app-adguardhome luci-app-autoreboot luci-app-firewall \
  luci-app-package-manager luci-app-pbr luci-app-samba4 \
  luci-app-smartdns luci-app-sqm luci-app-ttyd luci-app-upnp luci-app-vlmcsd luci-app-wol \
  luci-app-mosdns mosdns geo2txt

./scripts/feeds install -f -p istore \
  luci-app-store luci-lib-taskd luci-lib-xterm taskd

printf '\nCustom XinZhao feed installed with %d package entries.\n' "${#CUSTOM_PKGS[@]}"
