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
./scripts/feeds install mac80211 mt76 libnl-tiny >> "$OUT/feeds.log" 2>&1 || { tail -n 20 "$OUT/feeds.log"; die "feed install failed"; }
MT=package/feeds/base/mt76
MAC=package/feeds/base/mac80211
NL=package/feeds/base/libnl-tiny
[ -f "$MT/Makefile" ] && [ -f "$MAC/Makefile" ] && [ -f "$NL/Makefile" ] || die "mt76, mac80211 or libnl-tiny is not in the feed"

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
# The SDK's top makefile makes this directory before the first package; a
# package makefile that is run directly only writes into it.
mkdir -p "$STAGING_DIR/stamp"

# libnl-tiny and mac80211 are asked only for what mt76 needs from them:
# compiled, with headers and libraries in the staging directory. Their
# makefiles write a stamp file when that is done, and the stamp is the target
# here. A plain "compile" would go on to make packages of them, which nothing
# here needs.
staged() {
	make -C "$1" TOPDIR="$SDK" "$STAGING_DIR/stamp/.$2_installed" -j"$J" V=s > "$OUT/$2.log" 2>&1 ||
		{ grep -aE '\*\*\*|rror[: ]' "$OUT/$2.log" | head -n 20; die "$2 did not compile"; }
}

# libnl-tiny: the mt76 package also builds a small test tool that is linked
# against it. First, because it takes a minute and mac80211 a quarter of an
# hour.
echo "compiling libnl-tiny ..."
staged "$NL" libnl-tiny
[ -f "$STAGING_DIR/usr/include/libnl-tiny/unl.h" ] && ls "$STAGING_DIR"/usr/lib/libnl-tiny.so* > /dev/null 2>&1 ||
	die "libnl-tiny's headers and library are not in the staging directory"

# mac80211: its modules are compiled so that mt76 can be linked against their
# symbols; none of them goes into the image.
echo "compiling mac80211 ..."
staged "$MAC" mac80211
ls "$SDK"/build_dir/target-*/linux-*/symvers/mac80211.symvers > /dev/null 2>&1 ||
	die "mac80211 left no symbol list"
[ -d "$STAGING_DIR/usr/include/mac80211-backport" ] && [ -d "$STAGING_DIR/usr/include/mac80211" ] ||
	die "mac80211's headers are not in the staging directory"

# mt76 is packaged, because the modules are taken from the packages: stripped
# the way OpenWrt strips them. Packaging checks what every module depends on
# against the packages of mac80211 and of the kernel's own modules, and a
# clean SDK has built neither as packages (making them is the half hour this
# script avoids). The packages made here are only unpacked again below, so
# the check is switched off in this copy of the SDK. -k: a package of the
# set that still fails must not stop the two that are wanted.
[ -f scripts/gen-dependencies.sh ] || die "the SDK has no scripts/gen-dependencies.sh"
printf '#!/bin/sh\n# switched off by build-wifi-driver.sh\nexit 0\n' > scripts/gen-dependencies.sh
echo "compiling mt76 ..."
make -C "$MT" TOPDIR="$SDK" compile -k -j"$J" V=s > "$OUT/mt76.log" 2>&1 ||
	{ echo "mt76: make ended with an error:"; grep -aE -B2 -A8 'missing dependencies|rror[: ]' "$OUT/mt76.log" | grep -av '^make: \*\*\*' | head -n 40; }
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
