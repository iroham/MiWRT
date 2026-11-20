include $(TOPDIR)/rules.mk

# Tailscale for MiWRT: tailscaled with the command line built in, without the
# parts a headless router does not use (Tailscale SSH, Taildrop, Taildrive,
# web client, serve and funnel, cloud and Kubernetes support, client updates
# and so on). About 16 MB instead of 26 on arm64, 4.5 MB compressed. Kept:
# kernel TUN, nftables, subnet routes and exit nodes (offer and use), DERP,
# MagicDNS, NAT traversal with UPnP/NAT-PMP/PCP, Tailnet Lock, and reaching
# the control server through a proxy (HTTPS_PROXY), which the router's VPN
# provides where Tailscale is blocked. The feature list comes from the
# source's own tool: go run ./cmd/featuretags --min --add=cli,osrouter,
# netstack,dns,advertiseexitnode,advertiseroutes,useexitnode,useroutes,
# portmapper,useproxy,ipnbus,health,listenrawdisco,bakedroots,tailnetlock
#
# The recipe follows OpenWrt's tailscale package. The service stays off until
# it is switched on (option enabled in /etc/config/tailscale), from the app,
# the web interface or by hand.

PKG_NAME:=miwrt-tailscale
PKG_VERSION:=1.104.1
PKG_RELEASE:=1

PKG_SOURCE:=tailscale-$(PKG_VERSION).tar.gz
PKG_SOURCE_URL:=https://codeload.github.com/tailscale/tailscale/tar.gz/v$(PKG_VERSION)?
PKG_HASH:=bf868b2b1a46b9485d55bcda12c2d7573279ce4474bc6d607f42f1495db36ed8

PKG_MAINTAINER:=MiWRT
PKG_LICENSE:=BSD-3-Clause
PKG_LICENSE_FILES:=LICENSE

PKG_BUILD_DIR:=$(BUILD_DIR)/tailscale-$(PKG_VERSION)
PKG_BUILD_DEPENDS:=golang1.27/host
PKG_BUILD_PARALLEL:=1
PKG_BUILD_FLAGS:=no-mips16

GO_PKG:=tailscale.com/cmd/tailscaled
GO_PKG_LDFLAGS:=-X 'tailscale.com/version.longStamp=$(PKG_VERSION)-$(PKG_RELEASE) (MiWRT)'
GO_PKG_LDFLAGS_X:=tailscale.com/version.shortStamp=$(PKG_VERSION)
GO_PKG_TAGS:=ts_include_cli,ts_omit_ace,ts_omit_acme,ts_omit_appconnectors,ts_omit_aws,ts_omit_bird,ts_omit_cachenetmap,ts_omit_captiveportal,ts_omit_capture,ts_omit_cliconndiag,ts_omit_clientmetrics,ts_omit_clientupdate,ts_omit_cloud,ts_omit_colorable,ts_omit_completion,ts_omit_completion_scripts,ts_omit_conn25,ts_omit_dbus,ts_omit_debug,ts_omit_debugeventbus,ts_omit_debugportmapper,ts_omit_desktop_sessions,ts_omit_doctor,ts_omit_drive,ts_omit_flashappliance,ts_omit_gro,ts_omit_hujsonconf,ts_omit_identityfederation,ts_omit_iptables,ts_omit_kube,ts_omit_linkspeed,ts_omit_linuxdnsfight,ts_omit_logtail,ts_omit_netlog,ts_omit_networkmanager,ts_omit_oauthkey,ts_omit_outboundproxy,ts_omit_portlist,ts_omit_posture,ts_omit_qrcodes,ts_omit_relayserver,ts_omit_remoteconfig,ts_omit_resolved,ts_omit_routecheck,ts_omit_runtimemetrics,ts_omit_sdnotify,ts_omit_serve,ts_omit_serviceclientprefs,ts_omit_ssh,ts_omit_synology,ts_omit_syslog,ts_omit_syspolicy,ts_omit_systray,ts_omit_taildrop,ts_omit_tap,ts_omit_tpm,ts_omit_tundevstats,ts_omit_unixsocketidentity,ts_omit_usermetrics,ts_omit_wakeonlan,ts_omit_webbrowser,ts_omit_webclient

include $(INCLUDE_DIR)/package.mk
include $(TOPDIR)/feeds/packages/lang/golang/golang-package.mk

define Package/miwrt-tailscale
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=MiWRT
  TITLE:=Tailscale for routers (MiWRT build)
  URL:=https://tailscale.com
  DEPENDS:=$(GO_ARCH_DEPENDS) +ca-bundle +kmod-tun
  PROVIDES:=tailscale tailscaled
  CONFLICTS:=tailscale
endef

define Package/miwrt-tailscale/description
  Tailscale's tailscaled and tailscale in one program, built for a router.
  Off until switched on.
endef

define Package/miwrt-tailscale/conffiles
/etc/config/tailscale
/etc/tailscale/
endef

define Package/miwrt-tailscale/install
	$(INSTALL_DIR) $(1)/usr/sbin $(1)/etc/init.d $(1)/etc/config
	$(INSTALL_BIN) $(GO_PKG_BUILD_BIN_DIR)/tailscaled $(1)/usr/sbin
	$(LN) tailscaled $(1)/usr/sbin/tailscale
	$(INSTALL_BIN) ./files/tailscale.init $(1)/etc/init.d/tailscale
	$(INSTALL_CONF) ./files/tailscale.conf $(1)/etc/config/tailscale
endef

$(eval $(call BuildPackage,miwrt-tailscale))
