include $(TOPDIR)/rules.mk

PKG_NAME:=openclash-core
# APK version is transport metadata; immutable Core identity stays in the lock.
PKG_VERSION:=0.1.0_alpha
PKG_RELEASE:=1
PKGARCH:=aarch64_cortex-a53

include $(INCLUDE_DIR)/package.mk

# This package carries a reviewed, prebuilt AArch64 executable. ImmortalWrt's
# package-pack.mk invokes $(RSTRIP) for every package payload; keep the pinned
# Core bytes unchanged without disabling stripping for any other package.
RSTRIP:=:
STRIP:=:

define Package/openclash-core
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Official OpenClash Mihomo Meta and Smart Cores for Arthur
  DEPENDS:=@TARGET_qualcommax_ipq60xx
endef

define Package/openclash-core/description
  Pinned official OpenClash Meta and Smart Cores for JDCloud Arthur RE-SS-01.
  Both arm64 binaries are staged from immutable upstream Git blob pins.
endef

define Build/Prepare
	[ -x "$(CURDIR)/files/clash_meta" ] || { echo "Verified OpenClash Core was not staged" >&2; exit 1; }
	[ -x "$(CURDIR)/files/clash_smart" ] || { echo "Verified OpenClash Smart Core was not staged" >&2; exit 1; }
	[ -s "$(CURDIR)/files/clash_smart.sha256" ] || { echo "Verified OpenClash Smart Core SHA-256 is missing" >&2; exit 1; }
	$(INSTALL_DIR) $(PKG_BUILD_DIR)
	$(INSTALL_BIN) $(CURDIR)/files/clash_meta $(PKG_BUILD_DIR)/clash_meta
	$(INSTALL_BIN) $(CURDIR)/files/clash_smart $(PKG_BUILD_DIR)/clash_smart
	$(INSTALL_DATA) $(CURDIR)/files/clash_smart.sha256 $(PKG_BUILD_DIR)/clash_smart.sha256
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/openclash-core/install
	$(INSTALL_DIR) $(1)/etc/openclash/core
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/clash_meta $(1)/etc/openclash/core/clash_meta
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/clash_smart $(1)/etc/openclash/core/clash_smart
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/clash_smart.sha256 $(1)/etc/openclash/core/clash_smart.sha256
endef

$(eval $(call BuildPackage,openclash-core))
