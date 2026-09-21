include $(TOPDIR)/rules.mk

PKG_NAME:=openclash-core
# APK versions must start with a numeric component and use apk-tools suffix syntax.
# The immutable upstream core identity remains pinned separately in openclash-core.lock.json.
PKG_VERSION:=0.1.0_alpha
PKG_RELEASE:=1
PKGARCH:=aarch64_cortex-a53

include $(INCLUDE_DIR)/package.mk

# Preserve the pinned upstream prebuilt Meta Core byte-for-byte.
# OpenWrt's package pack step otherwise runs rstrip on ELF payloads.
RSTRIP:=:
STRIP:=:

define Package/openclash-core
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Official OpenClash Mihomo Meta Core for Arthur
  DEPENDS:=@TARGET_qualcommax_ipq60xx
endef

define Package/openclash-core/description
  Pinned official OpenClash Meta Core for JDCloud Arthur RE-SS-01.
  The build stages the upstream arm64 binary and verifies its immutable Git blob pin.
endef

define Build/Prepare
	[ -x "$(CURDIR)/files/clash_meta" ] || { echo "Verified OpenClash Core was not staged" >&2; exit 1; }
	$(INSTALL_DIR) $(PKG_BUILD_DIR)
	$(INSTALL_BIN) $(CURDIR)/files/clash_meta $(PKG_BUILD_DIR)/clash_meta
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/openclash-core/install
	$(INSTALL_DIR) $(1)/etc/openclash/core
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/clash_meta $(1)/etc/openclash/core/clash_meta
endef

$(eval $(call BuildPackage,openclash-core))
