#!/bin/sh
# What happens to a settings volume that outlives sysupgrade when the image
# under it changes: the clean-up 78_be7000_overlay_refresh runs at preinit and
# be7000-extroot runs for a USB disk, then be7000-romsync and be7000-feeds
# once the volume is mounted. Builds a made-up image and volume in a temporary
# directory and runs the real scripts on them.

set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/be7000-image-change.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

assert_eq() {
	[ "$1" = "$2" ] || fail "$3: expected '$2', got '$1'"
}

assert_file() {
	[ -f "$1" ] && [ ! -L "$1" ] || fail "$3: $1 is missing"
	assert_eq "$(cat "$1")" "$2" "$3"
}

assert_absent() {
	[ ! -e "$1" ] && [ ! -L "$1" ] || fail "$2: $1 is there"
}

# every path of a tree with the content of its files and the target of its links
snapshot() {
	(
		cd "$1"
		find . | sort
		find . -type f | sort | while read -r f; do printf '%s: ' "$f"; cat "$f"; echo; done
		find . -type l | sort | while read -r f; do printf '%s -> %s\n' "$f" "$(readlink "$f")"; done
	)
}

# BSD sed wants an argument after -i; the scripts are written for BusyBox
sed() {
	local a file tmp
	if [ "$1" != -i ]; then
		command sed "$@"
		return
	fi
	shift
	for a in "$@"; do file="$a"; done
	tmp="$TMP/sed.$$"
	command sed "$@" > "$tmp" || return 1
	cat "$tmp" > "$file"
	rm -f "$tmp"
}

LOG="$TMP/log"
: > "$LOG"
logger() { echo "logger: $*" >> "$LOG"; }
sync() { :; }

K1=50cf431c7d89e5743c65f203ecc18508
K2=0123456789abcdef0123456789abcdef
FEED_BASE=main-d958caf

# An overlayfs whiteout is a character device 0,0, which only root can make
# (and not in every container). Where it cannot be made a FIFO stands in for
# it, and the library is told to take a FIFO for a whiteout.
if mknod "$TMP/whiteout-probe" c 0 0 2>/dev/null; then
	REAL_WHITEOUTS=1
	rm -f "$TMP/whiteout-probe"
else
	REAL_WHITEOUTS=0
fi

whiteout() {
	mkdir -p "$(dirname "$1")"
	if [ "$REAL_WHITEOUTS" = 1 ]; then mknod "$1" c 0 0; else mkfifo "$1"; fi
}

is_whiteout() {
	if [ "$REAL_WHITEOUTS" = 1 ]; then [ -c "$1" ]; else [ -p "$1" ]; fi
}

# $1 directory, $2 build, $3 version, $4 kernel hash, $5 word that marks the content
make_rom() {
	local r="$1" build="$2" ver="$3" k="$4" w="$5" f
	rm -rf "$r"
	mkdir -p "$r/etc/config" "$r/etc/init.d" "$r/etc/rc.d" "$r/etc/modules.d" "$r/etc/uci-defaults" \
		"$r/etc/apk/repositories.d" "$r/etc/miwrt" "$r/lib/apk/db" "$r/lib/apk/packages" \
		"$r/lib/upgrade/keep.d" "$r/lib/functions" "$r/usr/share/ucode/miwrt" "$r/usr/sbin" "$r/root"
	if [ -n "$build" ]; then
		{
			echo "VERSION=$ver"
			echo "TAG=v$ver"
			echo "BUILD=$build"
			echo "KERNEL=$k"
			echo "FEED=$FEED_BASE"
		} > "$r/etc/miwrt-release"
	fi
	{
		echo "P:base-files"
		echo "V:1700~$w"
		echo
		echo "P:kmod-fake"
		echo "V:6.18.52-r1"
		echo "D:kernel=6.18.52~$k"
		echo
		echo "P:luci-theme-$w"
		echo "V:1"
	} > "$r/lib/apk/db/installed"
	echo "scripts $w" > "$r/lib/apk/db/scripts.tar.gz"
	echo "triggers $w" > "$r/lib/apk/db/triggers"
	printf '%s\n' "base-files=1700~$w" "kernel=6.18.52~$k" kmod-fake "luci-theme-$w" > "$r/etc/apk/world"
	# the keep lists the image really ships
	cp "$ROOT/overlay-files/etc/sysupgrade.conf" "$r/etc/sysupgrade.conf"
	cp "$ROOT/overlay-files/lib/upgrade/keep.d/miwrt" "$r/lib/upgrade/keep.d/miwrt"
	echo /etc/foo.conf > "$r/lib/apk/packages/foo.conffiles"
	# the feed list as the build workflow leaves it in an image
	command sed -e "s|feed/targets/qualcommbe/ipq95xx/packages/packages.adb|feed/targets/qualcommbe/ipq95xx/$k/packages/packages.adb|" \
		-e "s|feed/aarch64_cortex-a73/|feed/$FEED_BASE/aarch64_cortex-a73/|" \
		"$ROOT/overlay-files/etc/apk/repositories.d/customfeeds.list" > "$r/etc/apk/repositories.d/customfeeds.list"
	for f in etc/os-release etc/init.d/miwrt etc/modules.d/ath12k etc/uci-defaults/96-miwrt-app \
		etc/foo.conf etc/config/network etc/config/fstab etc/shadow etc/rc.local etc/miwrt/state.json \
		etc/kept-by-user etc/deleted-by-user lib/functions/x.sh usr/share/ucode/miwrt/hub.uc \
		usr/sbin/miwrt-update root/.profile; do
		echo "$w image $f" > "$r/$f"
	done
	ln -s ../init.d/miwrt "$r/etc/rc.d/S96miwrt"
	ln -s miwrt-update "$r/usr/sbin/be7000-tool"
}

# A volume that ran image "old" for a while: $1 directory, $2 the image it ran
make_volume() {
	local v="$1" old="$2" u="$1/upper" f
	rm -rf "$v"
	mkdir -p "$u/etc/config" "$u/etc/init.d" "$u/etc/rc.d" "$u/etc/modules.d" "$u/etc/apk/repositories.d" \
		"$u/etc/miwrt" "$u/lib/apk/db" "$u/lib/functions" "$u/usr/share/ucode/miwrt" "$u/usr/sbin" \
		"$u/usr/bin" "$u/root" "$v/work"
	# copies of image files, left by an apk upgrade or put there by hand
	for f in $COPIES; do
		echo "stale copy of $f" > "$u/$f"
	done
	ln -s /bin/busybox "$u/usr/sbin/be7000-tool"
	# what the user keeps
	for f in $KEPT; do
		echo "user's $f" > "$u/$f"
	done
	echo /etc/kept-by-user >> "$u/etc/sysupgrade.conf"
	ln -s ../init.d/custom "$u/etc/rc.d/S96miwrt"
	# the user's own files, which no image has
	echo tool > "$u/usr/bin/mytool"
	echo custom > "$u/etc/custom.conf"
	# what the user or a finished first-boot script removed
	whiteout "$u/etc/deleted-by-user"
	whiteout "$u/etc/uci-defaults/96-miwrt-app"
	whiteout "$u/etc/uci-defaults/20-of-an-older-image"
	# apk's database as the old image and one added package left it
	cp "$old/lib/apk/db/installed" "$u/lib/apk/db/installed"
	printf '\n%s\n%s\n' "P:tcpdump" "V:4" >> "$u/lib/apk/db/installed"
	cp "$old/lib/apk/db/scripts.tar.gz" "$old/lib/apk/db/triggers" "$u/lib/apk/db/"
	{ cat "$old/etc/apk/world"; echo tcpdump; } > "$u/etc/apk/world"
	cp "$old/etc/apk/repositories.d/customfeeds.list" "$u/etc/apk/repositories.d/customfeeds.list"
}

# the note inside a volume, and the question the preinit hook asks about it
NOTE=upper/etc/.be7000_image
note_volume() { echo "$2" > "$1/$NOTE"; }
vol_changed() { be7000_image_changed "$1" "$2/$NOTE" "$2/upper/lib/apk/db/installed"; }

COPIES="etc/os-release etc/init.d/miwrt etc/modules.d/ath12k lib/functions/x.sh usr/share/ucode/miwrt/hub.uc usr/sbin/miwrt-update"
KEPT="etc/config/network etc/config/fstab etc/foo.conf etc/shadow etc/rc.local etc/miwrt/state.json etc/kept-by-user etc/sysupgrade.conf root/.profile"

assert_copies_moved() {
	local v="$1" what="$2" f
	for f in $COPIES; do
		assert_absent "$v/upper/$f" "$what: copy still shadows the image"
		assert_file "$v/.be7000-replaced/$f" "stale copy of $f" "$what: moved copy"
	done
	assert_absent "$v/upper/usr/sbin/be7000-tool" "$what: link still shadows the image"
	assert_eq "$(readlink "$v/.be7000-replaced/usr/sbin/be7000-tool")" /bin/busybox "$what: moved link"
}

assert_kept() {
	local v="$1" what="$2" f
	for f in $KEPT; do
		[ "$f" = etc/sysupgrade.conf ] && continue
		assert_file "$v/upper/$f" "user's $f" "$what: kept file"
	done
	grep -qxF /etc/kept-by-user "$v/upper/etc/sysupgrade.conf" || fail "$what: sysupgrade.conf changed"
	assert_eq "$(readlink "$v/upper/etc/rc.d/S96miwrt")" ../init.d/custom "$what: rc.d link"
	assert_file "$v/upper/usr/bin/mytool" tool "$what: the user's own file"
	assert_file "$v/upper/etc/custom.conf" custom "$what: the user's own file"
	is_whiteout "$v/upper/etc/deleted-by-user" || fail "$what: whiteout of a deleted file is gone"
	is_whiteout "$v/upper/etc/uci-defaults/20-of-an-older-image" ||
		fail "$what: whiteout of a first-boot script the image does not have is gone"
	# the image's own first-boot script runs again: its whiteout is gone,
	# and since it held nothing it is not in the batch either
	assert_absent "$v/upper/etc/uci-defaults/96-miwrt-app" "$what: whiteout of the image's first-boot script"
	assert_absent "$v/.be7000-replaced/etc/uci-defaults" "$what: a whiteout was moved into the batch"
	grep -q '^P:tcpdump$' "$v/upper/lib/apk/db/installed" || fail "$what: preinit touched apk's database"
	grep -qx tcpdump "$v/upper/etc/apk/world" || fail "$what: preinit touched the world file"
	[ -f "$v/upper/etc/apk/repositories.d/customfeeds.list" ] || fail "$what: preinit moved the feed list"
}

# ---------------------------------------------------------------------------
# The library and the preinit hook
# ---------------------------------------------------------------------------

# The library with what a test must replace: the log goes to a file, and
# without real whiteouts a FIFO counts as one. be7000-extroot loads the
# library by itself, so it is given this file too.
BE7000_KEEP="$TMP/refresh.keep"
BE7000_FILES="$TMP/refresh.files"
{
	echo ". \"$ROOT/overlay-files/lib/functions/be7000-image.sh\""
	echo "be7000_refresh_log() { echo \"refresh: \$*\" >> \"$LOG\"; }"
	[ "$REAL_WHITEOUTS" = 1 ] || echo 'be7000_is_whiteout() { [ -p "$1" ]; }'
} > "$TMP/image-lib.sh"
. "$TMP/image-lib.sh"

OLD="$TMP/rom-old"
NEW="$TMP/rom-new"
V="$TMP/vol"
make_rom "$OLD" 1001 2.0.0 "$K1" old
make_rom "$NEW" 1002 2.1.0 "$K1" new
BE7000_IMAGE_ROOT="$NEW"

assert_eq "$(be7000_image_id "$NEW")" "BUILD=1002 VERSION=2.1.0" "image id"
assert_eq "$(be7000_image_kernel "$OLD/lib/apk/db/installed")" "$(be7000_image_kernel "$NEW/lib/apk/db/installed")" "the two images share a kernel"

# Same kernel, another build, and the volume knows which image it last ran.
make_volume "$V" "$OLD"
note_volume "$V" "BUILD=1001 VERSION=2.0.0"
vol_changed "$NEW" "$V" || fail "same kernel, other build: change not seen"
be7000_refresh_volume "$V"
assert_copies_moved "$V" "same kernel, other build"
assert_kept "$V" "same kernel, other build"
assert_file "$V/.be7000-replaced/.image" "BUILD=1002 VERSION=2.1.0" "batch label"
assert_file "$V/$NOTE" "BUILD=1001 VERSION=2.0.0" "preinit must leave the note to romsync"
grep -q "refresh: moved 7 copies" "$LOG" || fail "same kernel, other build: wrong count in the log: $(cat "$LOG")"
grep -qx "refresh: first-boot scripts of the image that run again: 96-miwrt-app" "$LOG" ||
	fail "same kernel, other build: first-boot scripts not in the log: $(cat "$LOG")"

# The next boot comes before romsync noted the image (bigoverlay runs the
# first boot on the slot's own overlay): the batch must survive.
echo "written after the refresh" > "$V/upper/etc/os-release"
before=$(snapshot "$V")
be7000_refresh_volume "$V"
assert_eq "$(snapshot "$V")" "$before" "second boot before romsync"

# Same build: nothing moves, whatever is in the overlay.
make_volume "$V" "$NEW"
note_volume "$V" "BUILD=1002 VERSION=2.1.0"
before=$(snapshot "$V")
if vol_changed "$NEW" "$V"; then
	fail "same build: taken for a change"
fi
be7000_refresh_volume "$V"
assert_eq "$(snapshot "$V")" "$before" "same build"
assert_absent "$V/.be7000-replaced" "same build"

# No note yet (the volume last ran an image older than the note) and its
# database is not this image's: a change.
make_volume "$V" "$OLD"
be7000_refresh_volume "$V"
assert_copies_moved "$V" "no note, other database"
assert_kept "$V" "no note, other database"

# No note and no database copy: a fresh install, or plain storage that
# sysupgrade wiped and then filled from the settings backup.
rm -rf "$V"
mkdir -p "$V/upper/etc/config" "$V/work"
echo "stale copy" > "$V/upper/etc/os-release"
echo "user's" > "$V/upper/etc/config/network"
before=$(snapshot "$V")
be7000_refresh_volume "$V"
assert_eq "$(snapshot "$V")" "$before" "no note, no database"

# No note and a database equal to the image's: nothing to clean either.
mkdir -p "$V/upper/lib/apk/db"
cp "$NEW/lib/apk/db/installed" "$V/upper/lib/apk/db/installed"
before=$(snapshot "$V")
be7000_refresh_volume "$V"
assert_eq "$(snapshot "$V")" "$before" "no note, same database"

# Plain storage right after sysupgrade: an empty volume.
rm -rf "$V"
mkdir -p "$V"
be7000_refresh_volume "$V"
assert_eq "$(ls -A "$V")" "" "empty volume"

# A changed kernel is still a change, even when the note says otherwise (an
# older image ran in between and does not keep the note).
make_rom "$TMP/rom-k2" 1002 2.1.0 "$K2" new
BE7000_IMAGE_ROOT="$TMP/rom-k2"
make_volume "$V" "$OLD"
note_volume "$V" "BUILD=1002 VERSION=2.1.0"
be7000_refresh_volume "$V"
assert_copies_moved "$V" "other kernel"
assert_kept "$V" "other kernel"
BE7000_IMAGE_ROOT="$NEW"

# An image built by hand has no release file: the kernel names it.
make_rom "$TMP/rom-hand" "" "" "$K2" hand
assert_eq "$(be7000_image_id "$TMP/rom-hand")" "kernel=6.18.52~$K2" "image id without a release file"
make_volume "$V" "$OLD"
note_volume "$V" "BUILD=1001 VERSION=2.0.0"
vol_changed "$TMP/rom-hand" "$V" || fail "hand-built image: change not seen"
note_volume "$V" "kernel=6.18.52~$K2"
cp "$TMP/rom-hand/lib/apk/db/installed" "$V/upper/lib/apk/db/installed"
if vol_changed "$TMP/rom-hand" "$V"; then
	fail "hand-built image: same image taken for a change"
fi

# A change with nothing to move keeps the batch of the change before it.
make_volume "$V" "$OLD"
note_volume "$V" "BUILD=1001 VERSION=2.0.0"
for f in $COPIES; do rm -f "$V/upper/$f"; done
rm -f "$V/upper/usr/sbin/be7000-tool"
mkdir -p "$V/.be7000-replaced/etc"
echo "BUILD=1001 VERSION=2.0.0" > "$V/.be7000-replaced/.image"
echo "from the update before" > "$V/.be7000-replaced/etc/os-release"
be7000_refresh_volume "$V"
assert_file "$V/.be7000-replaced/etc/os-release" "from the update before" "empty batch replaced the previous one"
assert_file "$V/.be7000-replaced/.image" "BUILD=1002 VERSION=2.1.0" "batch label after an empty batch"

# A batch with something in it replaces the previous one.
make_volume "$V" "$OLD"
note_volume "$V" "BUILD=1001 VERSION=2.0.0"
mkdir -p "$V/.be7000-replaced/etc"
echo "BUILD=1001 VERSION=2.0.0" > "$V/.be7000-replaced/.image"
echo "from the update before" > "$V/.be7000-replaced/etc/only-in-the-old-batch"
be7000_refresh_volume "$V"
assert_absent "$V/.be7000-replaced/etc/only-in-the-old-batch" "previous batch"
assert_copies_moved "$V" "new batch"

# Moving the settings (joining or releasing the spare slot) copies upper/ to a
# new volume. The note goes along, so a move is not taken for a new image even
# though the database, with the user's package in it, differs from the ROM's.
make_volume "$V" "$NEW"
note_volume "$V" "BUILD=1002 VERSION=2.1.0"
rm -rf "$TMP/vol-moved"
mkdir -p "$TMP/vol-moved/upper" "$TMP/vol-moved/work"
cp -a "$V/upper/." "$TMP/vol-moved/upper/"
before=$(snapshot "$TMP/vol-moved")
be7000_refresh_volume "$TMP/vol-moved"
assert_eq "$(snapshot "$TMP/vol-moved")" "$before" "settings moved to another volume"

# The preinit hook hands every mounted volume to the library and keeps no
# test of its own; the module hook stands alone and looks at the kernel only.
hook="$ROOT/overlay-files/lib/preinit/78_be7000_overlay_refresh"
sed -n '/^be7000_overlay_refresh_vol() {$/,/^}$/p' "$hook" | grep -F 'be7000_refresh_volume "$mnt"' >/dev/null ||
	fail "the mounted volume is not handed to be7000_refresh_volume"
grep -F 'kernel=' "$hook" >/dev/null && fail "the refresh hook compares kernels by itself again"
grep -F 'BE7000_IMAGE_ROOT=""' "$hook" >/dev/null || fail "the refresh hook does not name / as the image"
mod="$ROOT/overlay-files/lib/preinit/79_be7000_stale_modules"
assert_eq "$(grep -cF 'kernel=[0-9.]+~[0-9a-f]{32}' "$mod")" 2 "kernel comparisons in the module hook"
grep -E 'be7000-image|miwrt-release' "$mod" >/dev/null && fail "the module hook looks at the build"

# ---------------------------------------------------------------------------
# be7000-extroot: a USB disk is cleaned on the boot before it becomes /overlay
# ---------------------------------------------------------------------------

command sed -e '/be7000-factory-reset-guard\.sh/d' -e '/^YES=0$/,$d' \
	"$ROOT/overlay-files/usr/sbin/be7000-extroot" > "$TMP/extroot-functions"
. "$TMP/extroot-functions"
BE7000_IMAGE_LIB="$TMP/image-lib.sh"
BE7000_IMAGE_ROM="$NEW"
BE7000_RESET_TMP="$TMP"

# The disk: block names it, mount puts it where it is asked to. MOUNTED is
# what "mount" lists.
DISK="$TMP/disk"
DISK_UUID="1A2B-3C4D"
MOUNTED=""
MOUNT_CALLS=0
block() { printf '%s\n' '/dev/ubi0_2: UUID="0000" TYPE="ubifs"' "/dev/sda1: UUID=\"$DISK_UUID\" LABEL=\"be7000_overlay\" TYPE=\"ext4\""; }
mount() {
	local a dest=""
	if [ $# = 0 ]; then
		[ -z "$MOUNTED" ] || printf '%s\n' "$MOUNTED"
		return 0
	fi
	for a in "$@"; do dest="$a"; done
	MOUNT_CALLS=$((MOUNT_CALLS + 1))
	rmdir "$dest"
	ln -s "$DISK" "$dest"
}
umount() {
	rm "$1"
	mkdir "$1"
}
uname() { echo 6.18.52; }

# The disk last ran the old build. The UUID is matched whatever its case.
make_volume "$DISK" "$OLD"
note_volume "$DISK" "BUILD=1001 VERSION=2.0.0"
: > "$LOG"
prepare_disk 1a2b-3c4d
assert_eq "$MOUNT_CALLS" 1 "USB disk: mounts"
assert_copies_moved "$DISK" "USB disk"
assert_kept "$DISK" "USB disk"
assert_file "$DISK/.be7000-replaced/.image" "BUILD=1002 VERSION=2.1.0" "USB disk: batch label"
assert_file "$DISK/$NOTE" "BUILD=1001 VERSION=2.0.0" "USB disk: the note is left to romsync"
assert_eq "$(ls -d "$TMP"/extroot-prepare.* 2>/dev/null)" "" "USB disk: mount point left behind"
grep -q "refresh: moved 7 copies" "$LOG" || fail "USB disk: nothing in the log: $(cat "$LOG")"

# The same disk on a later boot of the same kind: nothing more to do.
before=$(snapshot "$DISK")
prepare_disk "$DISK_UUID"
assert_eq "$(snapshot "$DISK")" "$before" "USB disk: second time"

# A disk that already ran this image is only looked at.
make_volume "$DISK" "$NEW"
note_volume "$DISK" "BUILD=1002 VERSION=2.1.0"
before=$(snapshot "$DISK")
prepare_disk "$DISK_UUID"
assert_eq "$(snapshot "$DISK")" "$before" "USB disk: same build"

# A disk that is mounted (it is /overlay already) is not touched or mounted.
make_volume "$DISK" "$OLD"
note_volume "$DISK" "BUILD=1001 VERSION=2.0.0"
before=$(snapshot "$DISK")
MOUNTED="/dev/sda1 on /overlay type ext4 (rw,noatime)"
MOUNT_CALLS=0
prepare_disk "$DISK_UUID"
MOUNTED=""
assert_eq "$MOUNT_CALLS" 0 "USB disk in use: mounts"
assert_eq "$(snapshot "$DISK")" "$before" "USB disk in use"

# Another disk, or none: nothing is mounted.
prepare_disk FFFF-0000
prepare_disk ""
assert_eq "$MOUNT_CALLS" 0 "other disk: mounts"

# Modules built for another kernel are set aside on the disk, as the preinit
# hook does for the built-in volumes; with the same kernel they stay.
mkdir -p "$DISK/upper/lib/modules/6.18.52"
echo "old module" > "$DISK/upper/lib/modules/6.18.52/extra.ko"
prepare_disk "$DISK_UUID"
assert_file "$DISK/upper/lib/modules/6.18.52/extra.ko" "old module" "USB disk, same kernel: modules"
make_volume "$DISK" "$OLD"
note_volume "$DISK" "BUILD=1001 VERSION=2.0.0"
mkdir -p "$DISK/upper/lib/modules/6.18.52" "$DISK/upper/lib/modules.stale-ffff/6.18.52"
echo "old module" > "$DISK/upper/lib/modules/6.18.52/extra.ko"
BE7000_IMAGE_ROM="$TMP/rom-k2"
prepare_disk "$DISK_UUID"
BE7000_IMAGE_ROM="$NEW"
assert_file "$DISK/upper/lib/modules.stale-$K1/6.18.52/extra.ko" "old module" "USB disk, other kernel: modules set aside"
assert_absent "$DISK/upper/lib/modules" "USB disk, other kernel: modules still in place"
assert_absent "$DISK/upper/lib/modules.stale-ffff" "USB disk, other kernel: older set-aside modules"
assert_copies_moved "$DISK" "USB disk, other kernel"

# Both places where the boot check sends the router onto the disk get it
# ready first.
ext="$ROOT/overlay-files/usr/sbin/be7000-extroot"
sync_body=$(sed -n '/^cmd_boot_sync() {$/,/^}$/p' "$ext")
line_of() { printf '%s\n' "$sync_body" | grep -nF -- "$1" | head -1 | cut -d: -f1; }
[ "$(line_of 'prepare_disk "$extuuid"')" -lt "$(line_of 'touch "$marker"')" ] ||
	fail "the disk is not prepared before the first reboot onto it"
[ "$(line_of 'prepare_disk "$uuid"')" -lt "$(line_of 'rebooting once to put /overlay on it')" ] ||
	fail "the disk is not prepared before the reboot that puts /overlay on it"
BE7000_IMAGE_ROOT="$NEW"

# ---------------------------------------------------------------------------
# be7000-romsync: apk's database and the note on the volume
# ---------------------------------------------------------------------------

command sed '/be7000-image\.sh/d' "$ROOT/overlay-files/etc/init.d/be7000-romsync" > "$TMP/romsync-functions"
. "$TMP/romsync-functions"

# What the system sees once the volume is mounted over the image. A copy, not
# an overlay: note_back puts the one file romsync writes into the settings
# back where the overlay would have put it.
mount_merged() {
	M="$TMP/merged"
	rm -rf "$M"
	mkdir -p "$M"
	cp -a "$1/." "$M/"
	(cd "$2/upper" && find . \( -type f -o -type l \)) | while read -r f; do
		mkdir -p "$M/$(dirname "$f")"
		rm -f "$M/$f"
		cp -a "$2/upper/$f" "$M/$f"
	done
	ROM="$1"
	STASH="$2/.be7000-replaced"
	MARK="$M/etc/.be7000_image"
	DB="$M/lib/apk/db"
	DB_ROM="$1/lib/apk/db"
	WORLD="$M/etc/apk/world"
	WORLD_ROM="$1/etc/apk/world"
	PENDING="$M/etc/be7000-reinstall"
}

note_back() {
	cp "$MARK" "$1/$NOTE"
}

# Same kernel, another build, after the preinit hook did its part.
make_volume "$V" "$OLD"
note_volume "$V" "BUILD=1001 VERSION=2.0.0"
be7000_refresh_volume "$V"
mount_merged "$NEW" "$V"
: > "$LOG"
reconcile
cmp -s "$DB/installed" "$NEW/lib/apk/db/installed" || fail "romsync: the database still describes the old image"
cmp -s "$DB/scripts.tar.gz" "$NEW/lib/apk/db/scripts.tar.gz" || fail "romsync: old scripts archive"
cmp -s "$DB/triggers" "$NEW/lib/apk/db/triggers" || fail "romsync: old triggers"
assert_eq "$(sort "$WORLD" | tr '\n' ' ')" "$( { cat "$NEW/etc/apk/world"; echo luci-theme-old; echo tcpdump; } | sort | tr '\n' ' ')" "world after the change"
assert_eq "$(tr '\n' ' ' < "$PENDING")" "luci-theme-old tcpdump " "packages to reinstall"
assert_file "$MARK" "BUILD=1002 VERSION=2.1.0" "note after romsync"
assert_absent "$MARK.new" "note after romsync"
assert_absent "$V/.be7000-replaced/.image" "batch label after romsync"
assert_file "$V/.be7000-replaced/etc/os-release" "stale copy of etc/os-release" "romsync must not touch the batch"
grep -q "logger: -t be7000-romsync image changed (BUILD=1001 VERSION=2.0.0 -> BUILD=1002 VERSION=2.1.0)" "$LOG" ||
	fail "romsync: the change is not in the log: $(cat "$LOG")"
note_back "$V"

# The boot after that: nothing to do, at preinit or later.
rm -f "$PENDING"
: > "$LOG"
before=$(snapshot "$V")
be7000_refresh_volume "$V"
merged_before=$(snapshot "$M")
reconcile
assert_eq "$(snapshot "$V")" "$before" "boot after the change, volume"
assert_eq "$(snapshot "$M")" "$merged_before" "boot after the change, system"
assert_eq "$(cat "$LOG")" "" "boot after the change, log"

# No note and another database (the update that brings the note in).
make_volume "$V" "$OLD"
mount_merged "$NEW" "$V"
reconcile
cmp -s "$DB/installed" "$NEW/lib/apk/db/installed" || fail "romsync, no note: the database still describes the old image"
assert_file "$MARK" "BUILD=1002 VERSION=2.1.0" "note written on the first change"

# A fresh install: no note, no database copy. Only the note is written.
rm -rf "$V"
mkdir -p "$V/upper/etc/config" "$V/work"
echo "user's" > "$V/upper/etc/config/network"
mount_merged "$NEW" "$V"
merged_before=$(snapshot "$M")
: > "$LOG"
reconcile
assert_file "$MARK" "BUILD=1002 VERSION=2.1.0" "note on a fresh install"
assert_eq "$(cat "$LOG")" "" "fresh install, log"
note_back "$V"
rm -f "$MARK"
assert_eq "$(snapshot "$M")" "$merged_before" "fresh install, system"

# The user installed a package on the same image: not a change.
mkdir -p "$V/upper/lib/apk/db" "$V/upper/etc/apk"
{ cat "$NEW/lib/apk/db/installed"; printf '\n%s\n' "P:tcpdump"; } > "$V/upper/lib/apk/db/installed"
{ cat "$NEW/etc/apk/world"; echo tcpdump; } > "$V/upper/etc/apk/world"
mount_merged "$NEW" "$V"
merged_before=$(snapshot "$M")
reconcile
assert_eq "$(snapshot "$M")" "$merged_before" "package added on the same image"
assert_absent "$PENDING" "package added on the same image"

# Where the note cannot be written (no overlay, a read-only root) romsync
# carries on and leaves nothing behind.
rm -rf "$V"
mkdir -p "$V/upper/etc/config" "$V/work"
mount_merged "$NEW" "$V"
MARK="$TMP/no-such-dir/etc/.be7000_image"
merged_before=$(snapshot "$M")
reconcile
assert_eq "$(snapshot "$M")" "$merged_before" "note that cannot be written"
assert_absent "$TMP/no-such-dir" "note that cannot be written"

# The image build runs "enable" on init scripts from the build host, where
# /lib/functions is the host's: the library must be looked up in the image.
grep -F '. "${IPKG_INSTROOT}/lib/functions/be7000-image.sh"' "$ROOT/overlay-files/etc/init.d/be7000-romsync" >/dev/null ||
	fail "romsync does not load the library from the image being built"

# ---------------------------------------------------------------------------
# be7000-feeds: the feed list follows the image
# ---------------------------------------------------------------------------

. "$ROOT/overlay-files/etc/init.d/be7000-feeds"
LIST="$TMP/customfeeds.list"
ROM_LIST="$NEW/etc/apk/repositories.d/customfeeds.list"
RELEASE="$NEW/etc/miwrt-release"
{
	echo "# the list of an older image"
	echo "https://old.example.org/fw/feed/main-0000000/aarch64_cortex-a73/base/packages.adb"
	echo "https://old.example.org/fw/feed/main-0000000/aarch64_cortex-a73/gone/packages.adb"
	echo "https://old.example.org/fw/feed/targets/qualcommbe/ipq95xx/$K2/packages/packages.adb"
	echo "https://old.example.org/fw/feed/aarch64_cortex-a73/luci/packages.adb"
	echo "https://example.org/my-own-feed/packages.adb"
} > "$LIST"
: > "$LOG"
start
grep -E '^https?://' "$ROM_LIST" | while read -r l; do
	grep -qxF "$l" "$LIST" || fail "feed list: $l of the image is missing"
done
grep -q "old.example.org" "$LIST" && fail "feed list: lines of the old image are still there: $(cat "$LIST")"
grep -qxF "https://example.org/my-own-feed/packages.adb" "$LIST" || fail "feed list: the user's own feed is gone"
grep -qxF "# the list of an older image" "$LIST" || fail "feed list: a comment is gone"
assert_eq "$(grep -c "removed feed" "$LOG")" 4 "feed list: removed lines in the log"
before=$(cat "$LIST")
: > "$LOG"
start
assert_eq "$(cat "$LIST")" "$before" "feed list: second boot"
assert_eq "$(cat "$LOG")" "" "feed list: second boot, log"

# The image's own list, untouched, stays as it is.
cp "$ROM_LIST" "$LIST"
start
cmp -s "$ROM_LIST" "$LIST" || fail "feed list: the image's own list was changed"

# ---------------------------------------------------------------------------
# The theme's first-boot script, which now runs again after every update
# ---------------------------------------------------------------------------

UCI="$TMP/uci"
uci() {
	local k
	[ "$1" != -q ] || shift
	case "$1" in
	get) grep "^$2=" "$UCI" | cut -d= -f2- | grep . ;;
	set)
		k=${2%%=*}
		grep -v "^$k=" "$UCI" > "$UCI.new" || :
		echo "$2" >> "$UCI.new"
		mv "$UCI.new" "$UCI"
		;;
	commit) : ;;
	*) return 1 ;;
	esac
}
theme_script() {
	( IPKG_INSTROOT="$TMP/theme-root"; PKG_UPGRADE=""; . "$ROOT/luci-theme-miwrt/root/etc/uci-defaults/30_luci-theme-miwrt" )
}
mkdir -p "$TMP/theme-root/www/luci-static/miwrt" "$TMP/theme-root/www/luci-static/bootstrap"

# a fresh install: the theme is new here and becomes the one in use
echo "luci.main.mediaurlbase=/luci-static/bootstrap" > "$UCI"
theme_script
assert_eq "$(uci -q get luci.themes.MiWRT)" /luci-static/miwrt "theme registered"
assert_eq "$(uci -q get luci.main.mediaurlbase)" /luci-static/miwrt "theme in use on a fresh install"

# the user picks another installed theme: an update leaves it alone
uci set luci.main.mediaurlbase=/luci-static/bootstrap
theme_script
assert_eq "$(uci -q get luci.main.mediaurlbase)" /luci-static/bootstrap "a chosen theme after an update"

# the theme in use is not installed any more: back to the image's own
uci set luci.main.mediaurlbase=/luci-static/gone
theme_script
assert_eq "$(uci -q get luci.main.mediaurlbase)" /luci-static/miwrt "a theme that is gone"

# ---------------------------------------------------------------------------
# The app service's first-boot script: it switches the service on the first
# time only, so a service the user switched off stays off after an update
# ---------------------------------------------------------------------------

APP_LOG="$TMP/app-enable.log"
app_enable() { echo enable >> "$APP_LOG"; }
sed -e 's|/etc/init.d/miwrt enable|app_enable|' -e "s|/etc/miwrt|$TMP/app-etc|g" \
	"$ROOT/overlay-files/etc/uci-defaults/96-miwrt-app" > "$TMP/96-miwrt-app"
grep -q '^[[:space:]]*app_enable$' "$TMP/96-miwrt-app" || fail "app script: the line that switches the service on was not found"
grep -q '/etc/' "$TMP/96-miwrt-app" && fail "app script: a path of the real system is left in the copy under test"
app_script() {
	( . "$TMP/96-miwrt-app" )
}

# a fresh install
: > "$UCI"
: > "$APP_LOG"
app_script
assert_eq "$(uci -q get firewall.miwrt_block)" include "app script: firewall hook on a fresh install"
assert_eq "$(cat "$APP_LOG")" enable "app script: service switched on the first time"
[ -f "$TMP/app-etc/blocked.nft" ] || fail "app script: the list of paused devices was not created"

# after an update the script runs again: nothing is switched on a second time
: > "$APP_LOG"
echo "paused" > "$TMP/app-etc/blocked.nft"
app_script
assert_eq "$(cat "$APP_LOG")" "" "app script: a later run leaves the service as it is"
assert_eq "$(cat "$TMP/app-etc/blocked.nft")" paused "app script: the list of paused devices after a later run"

echo "image change tests: OK"
