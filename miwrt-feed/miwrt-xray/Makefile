include $(TOPDIR)/rules.mk

# Xray-core for MiWRT, built from the upstream release plus patches/. One
# build, two packages with the same program:
#   miwrt-xray     the program as it is (Redmi AC2100: room on flash, little
#                  memory, so the kernel can drop its pages and read them back)
#   miwrt-xray-xz  the program xz-compressed, unpacked into memory when it first
#                  runs (BE7000: 7 MB on the settings volume instead of 30,
#                  and memory to spare)
# Neither starts anything by itself: the tunnel manager owns configuration
# and service.

PKG_NAME:=miwrt-xray
PKG_VERSION:=26.11.9
PKG_RELEASE:=1

PKG_SOURCE:=Xray-core-$(PKG_VERSION).tar.gz
PKG_SOURCE_URL:=https://codeload.github.com/XTLS/Xray-core/tar.gz/v$(PKG_VERSION)?
PKG_HASH:=d5a47bed1b85e1cdfe3cb2f88a02e2db7144f0f8bee541d20b84fafa8fdf6c8d

PKG_MAINTAINER:=MiWRT
PKG_LICENSE:=MPL-2.0
PKG_LICENSE_FILES:=LICENSE

PKG_BUILD_DIR:=$(BUILD_DIR)/Xray-core-$(PKG_VERSION)
# Xray 26.11 needs Go 1.27; the OpenWrt 25.12 feeds default to 1.26 but carry 1.27
PKG_BUILD_DEPENDS:=golang1.27/host
PKG_BUILD_PARALLEL:=1
PKG_BUILD_FLAGS:=no-mips16

GO_PKG:=github.com/xtls/xray-core
GO_PKG_BUILD_PKG:=github.com/xtls/xray-core/main
GO_PKG_LDFLAGS_X:= \
	$(GO_PKG)/core.build=MiWRT \
	$(GO_PKG)/core.version=$(PKG_VERSION)

include $(INCLUDE_DIR)/package.mk
include $(TOPDIR)/feeds/packages/lang/golang/golang-package.mk

define Package/miwrt-xray/template
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=MiWRT
  URL:=https://github.com/XTLS/Xray-core
  PROVIDES:=xray
endef

define Package/miwrt-xray
  $(call Package/miwrt-xray/template)
  TITLE:=Xray-core proxy platform
  DEPENDS:=$(GO_ARCH_DEPENDS) +ca-bundle
  CONFLICTS:=xray-core miwrt-xray-xz
endef

define Package/miwrt-xray-xz
  $(call Package/miwrt-xray/template)
  TITLE:=Xray-core proxy platform (compressed on flash)
  DEPENDS:=$(GO_ARCH_DEPENDS) +ca-bundle +xz
  CONFLICTS:=xray-core miwrt-xray
endef

define Package/miwrt-xray/description
 Xray-core $(PKG_VERSION) with the MiWRT patches: on a processor without AES
 instructions the Chromium fingerprints offer ChaCha20 before AES-GCM, as
 Chrome does there. Installs /usr/bin/xray; starts nothing by itself.
endef

define Package/miwrt-xray-xz/description
 The same program as miwrt-xray, stored xz-compressed (about 7 MB instead of
 30) and unpacked into /tmp the first time it runs after a boot or an update.
 For routers with little flash and memory to spare.
endef

define Package/miwrt-xray/install
	$(call GoPackage/Package/Install/Bin,$(PKG_INSTALL_DIR))
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/usr/bin/main $(1)/usr/bin/xray
endef

# The compressed copy is made once, right after the Go build, so the slow
# xz -9e does not run again for every package that is written.
define Build/Compile
	$(call GoPackage/Build/Compile)
	$(CP) $(GO_PKG_BUILD_BIN_DIR)/main $(PKG_BUILD_DIR)/xray.stripped
	$(STRIP) $(PKG_BUILD_DIR)/xray.stripped
	sha256sum $(PKG_BUILD_DIR)/xray.stripped | cut -d' ' -f1 > $(PKG_BUILD_DIR)/xray.sha256
	# 32 MiB window: the whole program, and about 33 MB of memory to unpack it
	xz -c -T1 --check=crc32 --lzma2=preset=9e,dict=32MiB $(PKG_BUILD_DIR)/xray.stripped > $(PKG_BUILD_DIR)/xray.xz
endef

define Package/miwrt-xray-xz/install
	$(INSTALL_DIR) $(1)/usr/share/miwrt-xray $(1)/usr/bin
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/xray.xz $(PKG_BUILD_DIR)/xray.sha256 $(1)/usr/share/miwrt-xray/
	$(INSTALL_BIN) ./files/xray-xz.sh $(1)/usr/bin/xray
endef

define Package/miwrt-xray-xz/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || rm -rf /tmp/miwrt-xray
exit 0
endef

$(eval $(call BuildPackage,miwrt-xray))
$(eval $(call BuildPackage,miwrt-xray-xz))
