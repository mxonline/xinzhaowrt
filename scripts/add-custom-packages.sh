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

# 京东云亚瑟 IPQ60xx 的 OpenWrt 架构名为 arm_cortex-a7，而 quickstart
# 上游发布的是通用 arm 二进制。原 Makefile 的 @(x86_64||aarch64||arm)
# 条件在 ImmortalWrt 目标配置中不能正确表达该包的实际兼容范围，导致
# make defconfig 将 quickstart 及其上层 LuCI 包一起取消。这里仅修正云端
# 临时自定义 feed 的元数据：使用实际提供的 arm 二进制，并移除错误的
# 架构 Kconfig 限制；不修改设备 .config 或 required-plugins.txt。
# 不修改设备 .config，也不改变 required-plugins.txt 中的插件需求。
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

# 官方 iStore feed。luci-app-store 及其任务组件只从这里安装，禁止在
# .xinzhao-feed 中再放置同名 luci-app-store，避免 OpenWrt feed 冲突。
clone_or_update \
  istore \
  https://github.com/linkease/istore.git \
  main
ISTORE="$SOURCES/istore"
ISTORE_FEED="$ISTORE/luci"

# ImmortalWrt 官方 LuCI 应用 feed。以下六个 required package 都在
# immortalwrt/luci 的 applications 目录中，不使用第三方同名替代包。
clone_or_update \
  immortalwrt-luci \
  https://github.com/immortalwrt/luci.git \
  master
IMMORTAL_LUCI="$SOURCES/immortalwrt-luci"
for pkg in \
  luci-app-adguardhome luci-app-autoreboot luci-app-firewall \
  luci-app-package-manager luci-app-pbr luci-app-samba4 \
  luci-app-smartdns luci-app-sqm luci-app-ttyd luci-app-upnp \
  luci-app-vlmcsd luci-app-wol; do
  link_pkg "$pkg" "$IMMORTAL_LUCI/applications/$pkg"
done

# ImmortalWrt 官方 packages feed：补齐上述 LuCI 应用的运行时依赖。
clone_or_update \
  immortalwrt-packages \
  https://github.com/immortalwrt/packages.git \
  master
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

# MosDNS v5。上游 v5 分支仅提供 luci-app-mosdns 和 mosdns；不存在 v2dat package 目录。
clone_or_update \
  luci-app-mosdns \
  https://github.com/sbwml/luci-app-mosdns.git \
  v5
MOSDNS="$SOURCES/luci-app-mosdns"
link_pkg luci-app-mosdns "$MOSDNS/luci-app-mosdns"
link_pkg mosdns "$MOSDNS/mosdns"

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

# 防御性清理：只移除 xinzhao assembled feed 中的重复 store 包，不触碰
# required-plugins.txt、设备配置或任何源码仓库中的插件。
if [[ -e "$FEED/luci-app-store" ]]; then
  rm -rf "$FEED/luci-app-store"
  echo "REMOVED_DUPLICATE_PACKAGE: luci-app-store from .xinzhao-feed"
fi

# Register the assembled local feed.  Using a feed keeps package layout
# compatible with OpenWrt's normal package/feeds/<feed>/<package> structure.
if [[ ! -f feeds.conf ]]; then
  cp feeds.conf.default feeds.conf
fi

# 检查并补齐 ImmortalWrt 的官方基础 feed；不替换或删除 xinzhao 自定义 feed。
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

# Replace any same-named package installed from another feed with our selected
# source.  This avoids duplicate package definitions from broad feeds.
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

# Reinstall the complete unified iStore dependency chain after every selected
# package is known, so make defconfig sees all package symbols together.
./scripts/feeds install -f -p xinzhao \
  luci-app-istorex luci-app-quickstart quickstart \
  luci-app-adguardhome luci-app-autoreboot luci-app-firewall \
  luci-app-package-manager luci-app-pbr luci-app-samba4 \
  luci-app-smartdns luci-app-sqm luci-app-ttyd luci-app-upnp luci-app-vlmcsd luci-app-wol

# 通过官方 linkease/istore feed 安装 store 及其完整任务依赖。
./scripts/feeds install -f -p istore \
  luci-app-store luci-lib-taskd luci-lib-xterm taskd

printf '\nCustom XinZhao feed installed with %d package entries.\n' "${#CUSTOM_PKGS[@]}"
