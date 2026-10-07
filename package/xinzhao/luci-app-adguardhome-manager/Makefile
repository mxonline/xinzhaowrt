include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-adguardhome-manager
PKG_VERSION:=1.0
PKG_RELEASE:=1
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-adguardhome-manager
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=Full AdGuard Home LuCI manager for Arthur
  DEPENDS:=+luci-app-adguardhome +luci-compat +rpcd-mod-file
endef

define Package/luci-app-adguardhome-manager/description
  Installs the accepted Arthur CBI manager, lifecycle controls, templates and service files.
  The menu and rpcd ACL are supplied by the accepted rootfs overlay to override the feed SPA.
endef

define Package/luci-app-adguardhome-manager/conffiles
/etc/config/AdGuardHome
/etc/AdGuardHome.yaml
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/luci-app-adguardhome-manager/install
	$(INSTALL_DIR) $(1)/etc/config $(1)/etc/init.d $(1)/etc/uci-defaults $(1)/usr/libexec $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/model/cbi $(1)/usr/lib/lua/luci/view
	$(INSTALL_DIR) $(1)/usr/share/AdGuardHome
	$(INSTALL_DIR) $(1)/www/luci-static/resources/adguardhome
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/luci-app-adguardhome
	$(INSTALL_DATA) $(TOPDIR)/files/etc/config/AdGuardHome $(1)/etc/config/AdGuardHome
	$(INSTALL_DATA) $(TOPDIR)/files/etc/AdGuardHome.yaml $(1)/etc/AdGuardHome.yaml
	$(INSTALL_BIN) $(TOPDIR)/files/etc/init.d/AdGuardHome $(1)/etc/init.d/AdGuardHome
	$(INSTALL_DATA) $(TOPDIR)/files/etc/config/xinzhao-dns $(1)/etc/config/xinzhao-dns
	$(INSTALL_BIN) $(TOPDIR)/files/etc/init.d/xinzhao-dns-coexist $(1)/etc/init.d/xinzhao-dns-coexist
	$(INSTALL_BIN) $(TOPDIR)/files/usr/libexec/xinzhao-dns-coexist $(1)/usr/libexec/xinzhao-dns-coexist
	$(INSTALL_BIN) $(TOPDIR)/files/etc/uci-defaults/98-xinzhao-dns-coexist $(1)/etc/uci-defaults/98-xinzhao-dns-coexist
	$(INSTALL_DATA) $(TOPDIR)/files/usr/lib/lua/luci/controller/AdGuardHome.lua $(1)/usr/lib/lua/luci/controller/AdGuardHome.lua
	$(CP) $(TOPDIR)/files/usr/lib/lua/luci/model/cbi/AdGuardHome $(1)/usr/lib/lua/luci/model/cbi/
	$(CP) $(TOPDIR)/files/usr/lib/lua/luci/view/AdGuardHome $(1)/usr/lib/lua/luci/view/
	$(CP) $(TOPDIR)/files/usr/share/AdGuardHome/* $(1)/usr/share/AdGuardHome/
	$(CP) $(TOPDIR)/files/www/luci-static/resources/adguardhome/* $(1)/www/luci-static/resources/adguardhome/
	$(CP) $(TOPDIR)/files/www/luci-static/resources/view/luci-app-adguardhome/* $(1)/www/luci-static/resources/view/luci-app-adguardhome/
endef

$(eval $(call BuildPackage,luci-app-adguardhome-manager))
