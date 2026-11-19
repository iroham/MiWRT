#!/bin/sh
# Builds the two kernel modules of the Redmi AC2100's 5 GHz driver from
# OpenWrt's own mt76 source plus scripts/ac2100/mt76-patches, with the official
# OpenWrt SDK of the release the image is built from. The result has the
# layout of the image's root: OUT/lib/modules/<kernel>/mt7615-common.ko and
# mt7615e.ko. Only the Redmi AC2100 image build calls this.
#
#   scripts/ac2100/build-wifi-driver.sh SDK OUT
#     SDK  the unpacked OpenWrt SDK for ramips/mt7621
#     OUT  directory for the result and the build logs
#
# The wireless stack (mac80211) and mt76 are compiled straight from their
# package makefiles. "make package/mt76/compile" from the SDK's top would
# first package every kernel module of the release, which takes longer than
# everything else here.
set -eu

# the mt76 commit the patches are written for (OpenWrt 25.12.6)
MT76_COMMIT=39c960c3ada558b4c2e7915772483d3731573d09

HERE=$(cd "$(dirname "$0")" && pwd)
PATCHES=$HERE/mt76-patches
SDK=$(cd "$1" && pwd)
mkdir -p "$2"
OUT=$(cd "$2" && pwd)
die() { echo "build-wifi-driver: $*" >&2; exit 1; }

cd "$SDK"
[ -f feeds.conf.default ] || die "$SDK is not an OpenWrt SDK"

# only the base feed is needed: it holds mac80211 and mt76, at the commit the release was built from
grep -E '^src-git( --root=[^ ]+)? base ' feeds.conf.default > feeds.conf
[ -s feeds.conf ] || die "no base feed in the SDK's feeds.conf.default"
cat feeds.conf
./scripts/feeds update base > "$OUT/feeds.log" 2>&1 || { tail -n 20 "$OUT/feeds.log"; die "feed update failed"; }
./scripts/feeds install mac80211 mt76 >> "$OUT/feeds.log" 2>&1 || { tail -n 20 "$OUT/feeds.log"; die "feed install failed"; }
MT=package/feeds/base/mt76
MAC=package/feeds/base/mac80211
[ -f "$MT/Makefile" ] && [ -f "$MAC/Makefile" ] || die "mt76 or mac80211 is not in the feed"

have=$(sed -n 's/^PKG_SOURCE_VERSION:=//p' "$MT/Makefile")
[ "$have" = "$MT76_COMMIT" ] || die "the SDK builds mt76 $have, the patches are for $MT76_COMMIT: review them for the new version first"

mkdir -p "$MT/patches"
for p in "$PATCHES"/*.patch; do
	[ -e "$MT/patches/$(basename "$p")" ] && die "OpenWrt already has a patch named $(basename "$p")"
	cp "$p" "$MT/patches/"
	echo "added $(basename "$p")"
done

make defconfig > "$OUT/defconfig.log" 2>&1 || { tail -n 20 "$OUT/defconfig.log"; die "make defconfig failed"; }

# What the SDK's top makefile would put into the environment. Without the
# cross compiler in PATH the package makefiles compute an empty system include
# directory, the include order changes and mt76 no longer compiles.
tc=$(ls -d "$SDK"/staging_dir/toolchain-*/bin | head -n 1)
STAGING_DIR=$(ls -d "$SDK"/staging_dir/target-* | head -n 1)
export STAGING_DIR
PATH="$SDK/staging_dir/host/bin:$tc:$PATH"
export PATH
cc=$(ls "$tc"/*-openwrt-linux-musl-gcc | head -n 1)
[ -n "$("$cc" -print-file-name=include)" ] || die "the SDK's compiler does not run"
J=$(nproc 2>/dev/null || echo 2)

# mac80211: its modules are compiled so that mt76 can be linked against their
# symbols; none of them goes into the image. After compiling, this step also
# tries to package every wireless driver, and that part fails here for want of
# tools only a full build has. What mt76 needs is checked right below.
echo "compiling mac80211 ..."
make -C "$MAC" TOPDIR="$SDK" compile -j"$J" V=s > "$OUT/mac80211.log" 2>&1 ||
	echo "mac80211: packaging did not finish (expected); checking what mt76 needs"
ls "$SDK"/build_dir/target-*/linux-*/symvers/mac80211.symvers > /dev/null 2>&1 ||
	{ grep -aE '\*\*\*|rror:' "$OUT/mac80211.log" | head -n 20; die "mac80211 did not compile: no symbol list"; }
[ -d "$STAGING_DIR/usr/include/mac80211-backport" ] && [ -d "$STAGING_DIR/usr/include/mac80211" ] ||
	die "mac80211's headers are not in the staging directory"

echo "compiling mt76 ..."
make -C "$MT" TOPDIR="$SDK" compile -j"$J" V=s > "$OUT/mt76.log" 2>&1 ||
	{ grep -aE '\*\*\*|rror[: ]' "$OUT/mt76.log" | head -n 30; die "mt76 did not compile"; }
for p in "$PATCHES"/*.patch; do
	grep -aq "Applying .*$(basename "$p")" "$OUT/mt76.log" || die "$(basename "$p") was not applied"
done

# the modules as the packages carry them (stripped the way OpenWrt strips them)
x=$OUT/unpacked
rm -rf "$x" "$OUT/lib"
mkdir -p "$x"
for k in kmod-mt7615-common kmod-mt7615e; do
	f=$(ls "$SDK"/bin/targets/*/*/packages/"$k"-[0-9]*.apk 2>/dev/null | head -n 1)
	[ -n "$f" ] || die "no package $k was built"
	apk extract --allow-untrusted --destination "$x" "$f" > /dev/null 2>&1 || die "cannot unpack $f"
done
kver=$(ls "$x/lib/modules" | head -n 1)
[ -n "$kver" ] || die "the packages hold no modules"
mkdir -p "$OUT/lib/modules/$kver"
for m in mt7615-common.ko mt7615e.ko; do
	[ -s "$x/lib/modules/$kver/$m" ] || die "$m is not in the packages"
	cp "$x/lib/modules/$kver/$m" "$OUT/lib/modules/$kver/$m"
done
rm -rf "$x"

# the patched module has the switch, and both are for the release's kernel
strings "$OUT/lib/modules/$kver/mt7615-common.ko" | grep -q '^parmtype=txbf:bool$' || die "mt7615-common.ko has no txbf parameter"
for m in mt7615-common.ko mt7615e.ko; do
	v=$(strings "$OUT/lib/modules/$kver/$m" | sed -n 's/^vermagic=//p' | head -n 1)
	case "$v" in
	"$kver "*) echo "$m: $(wc -c < "$OUT/lib/modules/$kver/$m") bytes, vermagic $v" ;;
	*) die "$m is for '$v', not for kernel $kver" ;;
	esac
done
(cd "$OUT" && sha256sum lib/modules/"$kver"/*.ko | tee wifi-driver.sha256)
echo "build-wifi-driver: done"
