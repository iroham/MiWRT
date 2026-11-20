#!/bin/sh
# Builds the files/ directory the ImageBuilder copies into the Redmi AC2100
# image: the MiWRT pieces shared with the BE7000, taken from overlay-files and
# the LuCI packages by an explicit list, then overlay-ac2100 on top, then the
# release file. Nothing in overlay-files is changed; the BE7000 build does not
# read this script.
#
#   scripts/ac2100/assemble-files.sh OUT VERSION TAG BUILD OPENWRT
#     OUT      directory to create (must not exist or be empty)
#     VERSION  "2.0.0" for a release, "dev" otherwise
#     TAG      the release tag the image is built for (v2.1.0), or empty
#     BUILD    a build identifier (the CI run id)
#     OPENWRT  the OpenWrt release the ImageBuilder came from, e.g. 25.12.6
set -eu

OUT=$1 VERSION=$2 TAG=${3:-} BUILD=${4:-} OPENWRT=$5
REPO=$(cd "$(dirname "$0")/../.." && pwd)
DEVICE=openwrt-ramips-mt7621-xiaomi_redmi-router-ac2100
# releases carry the same tags as the BE7000 ones (v2.1.0) and hold the files
# of both routers; this router's checksum list has a name of its own there
TAG_PREFIX=v
SUMS=sha256sums-ac2100.txt
MODEL="Redmi AC2100"

[ -d "$OUT" ] && [ -n "$(ls -A "$OUT")" ] && { echo "$OUT is not empty" >&2; exit 1; }
mkdir -p "$OUT"

# copy one path (file or directory) from the repository, keeping modes and symlinks
take() {
	src=$REPO/$1 dst=$OUT/$2
	[ -e "$src" ] || [ -L "$src" ] || { echo "missing in the repository: $1" >&2; exit 1; }
	mkdir -p "$(dirname "$dst")"
	cp -a "$src" "$dst"
}

# --- the app service and its first-boot wiring (shared with the BE7000) ---
take overlay-files/etc/init.d/miwrt                      etc/init.d/miwrt
take overlay-files/etc/miwrt/blocked.nft                 etc/miwrt/blocked.nft
take overlay-files/etc/uci-defaults/94_be7000_hostname   etc/uci-defaults/94_miwrt_hostname
take overlay-files/etc/uci-defaults/96-miwrt-app         etc/uci-defaults/96-miwrt-app
take overlay-files/etc/uci-defaults/97-miwrt-sqm         etc/uci-defaults/97-miwrt-sqm
take overlay-files/lib/upgrade/keep.d/miwrt              lib/upgrade/keep.d/miwrt
take overlay-files/usr/share/miwrt/oui.txt               usr/share/miwrt/oui.txt
take overlay-files/www/cgi-bin/miwrt                     www/cgi-bin/miwrt
take overlay-files/usr/share/miwrt/api.uc                usr/share/miwrt/api.uc
take overlay-files/usr/share/miwrt/tick.uc               usr/share/miwrt/tick.uc
take overlay-files/etc/apk/commit_hooks.d/miwrt-compiled etc/apk/commit_hooks.d/miwrt-compiled
for f in extras hub power tunnel tailscale; do
	take overlay-files/usr/share/ucode/miwrt/$f.uc       usr/share/ucode/miwrt/$f.uc
done
for f in ctl discovery-relay hubd mdns-reflector push tuya upload wol tunnel tailscale; do
	take overlay-files/usr/sbin/miwrt-$f                 usr/sbin/miwrt-$f
done

# --- the rest of what MiWRT adds to LuCI and the system on every router ---
# Overview card with the version and links (model-aware), the credits page,
# the "State" LED trigger with its watcher, the network-restart offer after a
# package adds a netifd protocol, the SSH greeting with the credits, and the
# class that follows the router when its own address is changed in LuCI
take overlay-files/www/luci-static/resources/view/status/include/05_be7000.js   www/luci-static/resources/view/status/include/05_be7000.js
take overlay-files/www/luci-static/resources/view/be7000-credits/credits.js     www/luci-static/resources/view/be7000-credits/credits.js
take overlay-files/www/luci-static/resources/be7000-credits/credits.json         www/luci-static/resources/be7000-credits/credits.json
take overlay-files/usr/share/luci/menu.d/luci-app-be7000-credits.json            usr/share/luci/menu.d/luci-app-be7000-credits.json
take overlay-files/usr/share/rpcd/acl.d/luci-app-be7000-credits.json             usr/share/rpcd/acl.d/luci-app-be7000-credits.json
take overlay-files/usr/libexec/led-trigger/be7000-state                          usr/libexec/led-trigger/be7000-state
take overlay-files/www/luci-static/resources/view/system/led-trigger/be7000-state.js www/luci-static/resources/view/system/led-trigger/be7000-state.js
take overlay-files/usr/libexec/be7000-leds                                       usr/libexec/be7000-leds
take overlay-files/etc/init.d/be7000-leds                                        etc/init.d/be7000-leds
take overlay-files/etc/rc.d/S97be7000-leds                                       etc/rc.d/S97be7000-leds
take overlay-files/etc/apk/commit_hooks.d/be7000-netifd-proto                    etc/apk/commit_hooks.d/be7000-netifd-proto
take overlay-files/usr/libexec/be7000-netifd                                     usr/libexec/be7000-netifd
take overlay-files/usr/share/rpcd/ucode/be7000-netifd                            usr/share/rpcd/ucode/be7000-netifd
take overlay-files/usr/share/rpcd/acl.d/luci-app-be7000-netifd.json              usr/share/rpcd/acl.d/luci-app-be7000-netifd.json
take overlay-files/usr/libexec/be7000-banner                                     usr/libexec/be7000-banner
take overlay-files/etc/init.d/be7000-banner                                      etc/init.d/be7000-banner
take overlay-files/etc/rc.d/S96be7000-banner                                     etc/rc.d/S96be7000-banner
take overlay-files/www/luci-static/resources/preload/lanmove.js                  www/luci-static/resources/preload/lanmove.js

# --- the setup assistant a fresh install opens with (AdGuard Home on the router itself is
#     BE7000 only: it needs more memory than this router has, and the assistant says so) ---
take overlay-files/etc/uci-defaults/98-miwrt-setup                              etc/uci-defaults/98-miwrt-setup
take overlay-files/usr/share/ucode/miwrt/setup.uc                               usr/share/ucode/miwrt/setup.uc
take overlay-files/usr/share/ucode/miwrt/channels.uc                            usr/share/ucode/miwrt/channels.uc
take overlay-files/usr/libexec/miwrt-setup-apply                                usr/libexec/miwrt-setup-apply
take overlay-files/usr/share/rpcd/ucode/miwrt-setup                             usr/share/rpcd/ucode/miwrt-setup
take overlay-files/usr/share/rpcd/acl.d/luci-app-miwrt-setup.json               usr/share/rpcd/acl.d/luci-app-miwrt-setup.json
take overlay-files/usr/share/luci/menu.d/luci-app-miwrt-setup.json              usr/share/luci/menu.d/luci-app-miwrt-setup.json
take overlay-files/www/luci-static/resources/view/miwrt-setup                   www/luci-static/resources/view/miwrt-setup
take overlay-files/www/luci-static/resources/miwrt-setup                        www/luci-static/resources/miwrt-setup

# --- VPN: the Xray client and the router link (Xray itself installs from the MiWRT feed when
#     asked for), and the Tailscale page (Tailscale is not in this image: the page installs it
#     from the MiWRT feed and removes it again) ---
take overlay-files/etc/init.d/miwrt-tunnel                                      etc/init.d/miwrt-tunnel
take overlay-files/etc/hotplug.d/iface/95-miwrt-tunnel                          etc/hotplug.d/iface/95-miwrt-tunnel
take overlay-files/usr/share/rpcd/ucode/miwrt-vpn                               usr/share/rpcd/ucode/miwrt-vpn
take overlay-files/usr/share/rpcd/acl.d/luci-app-miwrt-vpn.json                 usr/share/rpcd/acl.d/luci-app-miwrt-vpn.json
take overlay-files/usr/share/luci/menu.d/luci-app-miwrt-vpn.json                usr/share/luci/menu.d/luci-app-miwrt-vpn.json
take overlay-files/www/luci-static/resources/miwrtvpn.js                        www/luci-static/resources/miwrtvpn.js
take overlay-files/www/luci-static/resources/view/miwrt-vpn                     www/luci-static/resources/view/miwrt-vpn

# --- the LuCI translations of every MiWRT page (the sources are Russian) ---
for l in en zh-cn; do
	take overlay-files/usr/lib/lua/luci/i18n/be7000.$l.lmo usr/lib/lua/luci/i18n/be7000.$l.lmo
done

# --- the MiWRT theme, as luci.mk would install it ---
take luci-theme-miwrt/htdocs/luci-static/miwrt                        www/luci-static/miwrt
take luci-theme-miwrt/htdocs/luci-static/resources/menu-miwrt.js      www/luci-static/resources/menu-miwrt.js
take luci-theme-miwrt/root/etc/uci-defaults/30_luci-theme-miwrt      etc/uci-defaults/30_luci-theme-miwrt
take luci-theme-miwrt/ucode/template/themes/miwrt                     usr/share/ucode/luci/template/themes/miwrt

# --- System, Build update: the page, its backend and the updater ---
U=awg-feed/luci-app-be7000-update
take $U/htdocs/luci-static/resources/view/be7000-update                 www/luci-static/resources/view/be7000-update
take $U/htdocs/luci-static/resources/view/status/include/04_be7000_update.js www/luci-static/resources/view/status/include/04_be7000_update.js
take $U/root/etc/init.d/be7000-update-check                              etc/init.d/be7000-update-check
take $U/root/etc/uci-defaults/luci-app-be7000-update                     etc/uci-defaults/luci-app-be7000-update
take $U/root/usr/sbin/miwrt-update                                       usr/sbin/miwrt-update
take $U/root/usr/share/luci/menu.d/luci-app-be7000-update.json           usr/share/luci/menu.d/luci-app-be7000-update.json
take $U/root/usr/share/rpcd/acl.d/luci-app-be7000-update.json            usr/share/rpcd/acl.d/luci-app-be7000-update.json
take $U/root/usr/share/rpcd/ucode/be7000-update                          usr/share/rpcd/ucode/be7000-update

# --- everything only this router has ---
cp -a "$REPO/overlay-ac2100/." "$OUT/"
rm -f "$OUT/README.md"

# --- the release file miwrt-update, the banner and the identity script read ---
mkdir -p "$OUT/etc"
{
	echo "VERSION=$VERSION"
	echo "TAG=$TAG"
	echo "DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	echo "BUILD=$BUILD"
	echo "DEVICE=$DEVICE"
	echo "TAG_PREFIX=$TAG_PREFIX"
	echo "SUMS=$SUMS"
	echo "MODEL=$MODEL"
	echo "BASE=OpenWrt $OPENWRT"
} > "$OUT/etc/miwrt-release"

# --- the MiWRT package feed of this router (scripts/ac2100/build-feed.sh), next
#     to OpenWrt's own; its index is signed with the key the workflow adds as
#     etc/apk/keys/public-key.pem. Every feed listed has to exist: "apk update"
#     fails as a whole when one of them answers 404 ---
mkdir -p "$OUT/etc/apk/repositories.d"
echo "https://iroham.github.io/MiWRT/feed/ac2100/$OPENWRT/mipsel_24kc/miwrt/packages.adb" > "$OUT/etc/apk/repositories.d/miwrt.list"

# the shared scripts expect to be executable and the app's state directory to be private
chmod 755 "$OUT"/etc/init.d/* "$OUT"/etc/uci-defaults/* "$OUT"/usr/sbin/* "$OUT"/www/cgi-bin/miwrt "$OUT"/usr/libexec/be7000-* "$OUT"/usr/libexec/miwrt-setup-apply "$OUT"/etc/apk/commit_hooks.d/* "$OUT"/etc/hotplug.d/iface/95-miwrt-tunnel
chmod 700 "$OUT/etc/miwrt"

echo "assembled $(find "$OUT" -type f | wc -l) files and $(find "$OUT" -type l | wc -l) links into $OUT"
