#!/bin/sh
# Builds the MiWRT package feed of the Redmi AC2100 (mipsel_24kc) from
# miwrt-feed/ with the official OpenWrt SDK of the release the image is built
# from, and writes its index, signed when a key is given. What the packages
# need at run time (ca-bundle, xz) comes from OpenWrt's own feeds on the router.
#
#   scripts/ac2100/build-feed.sh SDK OUT [KEY]
#     SDK  the unpacked OpenWrt SDK for ramips/mt7621
#     OUT  directory for the result (OUT/miwrt/*.apk and packages.adb) and the logs
#     KEY  the apk signing key (private, PEM); without it the index is unsigned
#
# The packages built are the ones listed in PACKAGES below.
set -eu

PACKAGES="miwrt-xray miwrt-xray-xz miwrt-tailscale"

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
SDK=$(cd "$1" && pwd)
mkdir -p "$2"
OUT=$(cd "$2" && pwd)
KEY=${3:-}
die() { echo "build-feed: $*" >&2; exit 1; }

cd "$SDK"
[ -f feeds.conf.default ] || die "$SDK is not an OpenWrt SDK"

# base and packages at the commits the release was built from, plus ours
grep -E '^src-git( --root=[^ ]+)? (base|packages) ' feeds.conf.default > feeds.conf
[ "$(wc -l < feeds.conf)" = 2 ] || die "base or packages feed missing in the SDK's feeds.conf.default"
echo "src-link miwrt $REPO/miwrt-feed" >> feeds.conf
cat feeds.conf
./scripts/feeds update base packages miwrt > "$OUT/feeds.log" 2>&1 || { tail -n 20 "$OUT/feeds.log"; die "feed update failed"; }
# with their build and run dependencies (Go, ca-bundle, xz, kmod-tun) from the other two
./scripts/feeds install -p miwrt $PACKAGES >> "$OUT/feeds.log" 2>&1 || { tail -n 20 "$OUT/feeds.log"; die "feed install failed"; }

if [ -n "$KEY" ]; then
	cp "$KEY" private-key.pem
	chmod 600 private-key.pem
fi
# only what is listed here: the SDK's default selects every package of every
# feed. The settings go on top of the SDK's own configuration (its target).
make defconfig > "$OUT/defconfig.log" 2>&1 || { tail -n 20 "$OUT/defconfig.log"; die "make defconfig failed"; }
sed -i -E '/^(# )?CONFIG_(ALL|ALL_NONSHARED|ALL_KMODS|SIGNED_PACKAGES)[= ]/d' .config
{
	echo "# CONFIG_ALL is not set"
	echo "# CONFIG_ALL_NONSHARED is not set"
	echo "# CONFIG_ALL_KMODS is not set"
	if [ -n "$KEY" ]; then echo "CONFIG_SIGNED_PACKAGES=y"; else echo "# CONFIG_SIGNED_PACKAGES is not set"; fi
	for p in $PACKAGES; do echo "CONFIG_PACKAGE_$p=m"; done
} >> .config
make defconfig > "$OUT/defconfig.log" 2>&1 || { tail -n 20 "$OUT/defconfig.log"; die "make defconfig failed"; }
for p in $PACKAGES; do
	grep -q "^CONFIG_PACKAGE_$p=m" .config || die "$p did not survive defconfig (a dependency missing?)"
done

# one source package makes both Xray packages; Tailscale is a source package of its own
for s in miwrt-xray miwrt-tailscale; do
	make package/$s/compile -j"$(nproc)" V=s >> "$OUT/compile.log" 2>&1 || { tail -n 80 "$OUT/compile.log"; die "compile of $s failed"; }
done

arch=$(sed -n 's/^CONFIG_TARGET_ARCH_PACKAGES="\(.*\)"/\1/p' .config)
[ -n "$arch" ] || die "no package architecture in .config"
src=bin/packages/$arch/miwrt
for p in $PACKAGES; do
	ls "$src/$p"-[0-9]*.apk > /dev/null 2>&1 || die "$p was not built"
done
make package/index V=s > "$OUT/index.log" 2>&1 || { tail -n 30 "$OUT/index.log"; die "index failed"; }
[ -s "$src/packages.adb" ] || die "no index in $src"

rm -rf "$OUT/miwrt"
mkdir -p "$OUT/miwrt"
cp "$src"/*.apk "$src/packages.adb" "$OUT/miwrt/"
rm -f private-key.pem
echo "$arch" > "$OUT/arch"
ls -la "$OUT/miwrt"
