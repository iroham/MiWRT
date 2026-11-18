#!/bin/sh
# Storage settings against the real uci: the fstab helpers, the USB wizard
# (be7000-extroot use / revert / boot-sync), the checks of the slot storage
# and bigoverlay writers, and the tool behind "cancel the reset"
# (be7000-reset).
#
# The other tests replace uci with a stub. This one is about what uci itself
# does (it answers success for a batch that wrote nothing), so it needs the
# real program and runs on a router:
#
#   tar -C <repo> -cf - overlay-files/lib/functions overlay-files/usr/sbin/be7000-extroot \
#       overlay-files/usr/libexec overlay-files/etc/init.d/bigoverlay scripts/test-storage-fstab.sh |
#       ssh root@<router> 'mkdir -p /tmp/miwrt-test && tar -C /tmp/miwrt-test -xf -'
#   ssh root@<router> 'sh /tmp/miwrt-test/scripts/test-storage-fstab.sh'
#
# Everything happens in a directory of its own under /tmp. Disks, volumes,
# mount, block, mkfs and reboot are stand-ins; the router's own settings and
# storage are not read or written. Without uci (a desktop) the test says so
# and ends.

# no -u: the scripts under test run without it on the router
set -e

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)

REAL_UCI=$(command -v uci 2>/dev/null) || REAL_UCI=
if [ -z "$REAL_UCI" ]; then
	echo "storage fstab tests: SKIPPED, there is no uci on this machine (run it on a router, see the head of the script)"
	exit 0
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/be7000-storage-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

fail() { echo "FAIL: $*" >&2; exit 1; }

clear_dir() {
	local d="$1" p
	mkdir -p "$d"
	for p in "$d"/* "$d"/.[!.]* "$d"/..?*; do
		[ -e "$p" ] || [ -L "$p" ] || continue
		rm -rf "$p"
	done
}

# what a tree holds: names, kinds and file contents
tree_sum() {
	( cd "$1" && find . | sort | while IFS= read -r p; do
		if [ -L "$p" ]; then echo "l $p"
		elif [ -d "$p" ]; then echo "d $p"
		else echo "f $p $(md5sum < "$p")"; fi
	done )
}

# --- stand-ins ---------------------------------------------------------------

BIN="$TMP/bin"
mkdir -p "$BIN" "$TMP/uci-save"

# uci: the real one, with its place for pending changes moved into the test
# directory and the router's own settings out of reach (no -c means the test's
# live settings). A config directory that matches the pattern in uci-drop
# takes a batch the way a full or missing file does: success, nothing written.
cat > "$BIN/uci" <<EOF
#!/bin/sh
T='$TMP'
REAL='$REAL_UCI'
dir=""; prev=""; sub=""
for a in "\$@"; do
	[ "\$prev" = -c ] && dir="\$a"
	case "\$a" in
	batch|get|set|add|delete|commit|revert|changes|show) [ -n "\$sub" ] || [ "\$prev" = -c ] || sub="\$a" ;;
	esac
	prev="\$a"
done
if [ "\$sub" = batch ] && [ -s "\$T/uci-drop" ]; then
	pat=\$(cat "\$T/uci-drop")
	case "\${dir:-\$(cat "\$T/live")}" in
	\$pat) cat >/dev/null; exit 0 ;;
	esac
fi
if [ -n "\$dir" ]; then
	exec "\$REAL" -t "\$T/uci-save" "\$@"
fi
exec "\$REAL" -t "\$T/uci-save" -c "\$(cat "\$T/live")" "\$@"
EOF

# mount: no arguments prints the table; otherwise the device's stand-in
# directory is copied to the mount point, and umount copies it back.
cat > "$BIN/mount" <<EOF
#!/bin/sh
T='$TMP'
[ \$# -gt 0 ] || { cat "\$T/mount.out"; exit 0; }
src=""; dest=""
for a in "\$@"; do src="\$dest"; dest="\$a"; done
back=\$(awk -v s="\$src" '\$1 == s { print \$2; exit }' "\$T/devices")
[ -n "\$back" ] || exit 1
if [ -f "\$T/mount-fail" ] && grep -qx "\$src" "\$T/mount-fail"; then exit 1; fi
case "\$dest" in /tmp/*|"\$T"/*) ;; *) exit 1 ;; esac
mkdir -p "\$dest" || exit 1
[ -z "\$(ls -A "\$dest")" ] || exit 1
cp -a "\$back"/. "\$dest"/ || exit 1
echo "\$dest \$back" >> "\$T/mounted"
echo "mount \$src" >> "\$T/calls"
EOF

cat > "$BIN/umount" <<EOF
#!/bin/sh
T='$TMP'
back=\$(awk -v d="\$1" '\$1 == d { b = \$2 } END { print b }' "\$T/mounted" 2>/dev/null)
[ -n "\$back" ] || exit 1
for p in "\$back"/* "\$back"/.[!.]* "\$back"/..?*; do
	[ -e "\$p" ] || [ -L "\$p" ] || continue
	rm -rf "\$p"
done
cp -a "\$1"/. "\$back"/ || exit 1
for p in "\$1"/* "\$1"/.[!.]* "\$1"/..?*; do
	[ -e "\$p" ] || [ -L "\$p" ] || continue
	rm -rf "\$p"
done
awk -v d="\$1" '\$1 != d' "\$T/mounted" > "\$T/mounted.new"
mv "\$T/mounted.new" "\$T/mounted"
EOF

# block info: the list in block.out; asked about one device it stays silent,
# as the real one does for some kinds of device
cat > "$BIN/block" <<EOF
#!/bin/sh
T='$TMP'
[ "\$1" = info ] && [ \$# = 1 ] && cat "\$T/block.out" 2>/dev/null
exit 0
EOF

# mkfs.ext4: notes whether the live fstab was there when the disk was erased,
# and leaves an empty filesystem
cat > "$BIN/mkfs.ext4" <<EOF
#!/bin/sh
T='$TMP'
if [ -f "\$(cat "\$T/live")/fstab" ]; then echo "mkfs fstab-present" >> "\$T/calls"; else echo "mkfs fstab-missing" >> "\$T/calls"; fi
for p in "\$T/disk"/* "\$T/disk"/.[!.]* "\$T/disk"/..?*; do
	[ -e "\$p" ] || [ -L "\$p" ] || continue
	rm -rf "\$p"
done
exit 0
EOF

for n in logger reboot; do
	printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\n' "$n" "$TMP" > "$BIN/$n"
done
printf '#!/bin/sh\nexit 0\n' > "$BIN/sync"
chmod +x "$BIN"/*
PATH="$BIN:$PATH"
export PATH
# nothing below may reach the router's own mount, mkfs or reboot
for n in uci mount umount block mkfs.ext4 logger reboot sync; do
	[ "$(command -v "$n")" = "$BIN/$n" ] || fail "test setup: $n is not the stand-in"
done

LIB="$ROOT/overlay-files/lib/functions/be7000-fstab.sh"
BE7000_FSTAB_LIB="$LIB"
BE7000_RESET_SYS_UBI="$TMP/sys/class/ubi"
BE7000_RESET_PROC_MOUNTS="$TMP/proc.mounts"
BE7000_RESET_TMP="$TMP"
export BE7000_FSTAB_LIB BE7000_RESET_SYS_UBI BE7000_RESET_PROC_MOUNTS BE7000_RESET_TMP

mkdir -p "$TMP/sys/class/ubi/ubi0_2" "$TMP/sys/class/ubi/ubi1_1" "$TMP/dev"
echo rootfs_data > "$TMP/sys/class/ubi/ubi0_2/name"
echo cfg > "$TMP/sys/class/ubi/ubi1_1/name"

DISK="$TMP/dev/sda1"
mknod "$DISK" b 7 99 2>/dev/null || fail "cannot make a block device node for the test (run it as root)"

UUID=0f3a9c1e-6b7d-4e2a-9c55-1d2e3f4a5b6c
: > "$TMP/calls"

. "$LIB"

# --- 1. what uci does, which is why the helpers exist -------------------------

mkdir -p "$TMP/premise"
echo "$TMP/premise" > "$TMP/live"
rc=0
printf "set fstab.extroot=mount\nset fstab.extroot.target='/overlay'\ncommit fstab\n" |
	uci -q -c "$TMP/premise" batch >/dev/null 2>&1 || rc=$?
if [ "$rc" = 0 ] && [ ! -s "$TMP/premise/fstab" ]; then
	echo "premise holds: uci batch on a missing fstab answers success and writes nothing"
else
	echo "note: this uci does not answer success for a batch on a missing file (rc $rc); the helpers stay correct either way"
fi
uci -q -c "$TMP/premise" revert fstab 2>/dev/null || true

# --- 2. the helpers ------------------------------------------------------------

D="$TMP/lib1/etc/config"
be7000_fstab_ensure "$D" || fail "ensure did not make fstab in a directory that was not there"
[ -f "$D/fstab" ] || fail "ensure answered success without a file"
[ "$(be7000_fstab_get "$D" '@global[0]')" = global ] || fail "ensure left no global section"
[ "$(be7000_fstab_get "$D" '@global[0].delay_root')" = 5 ] || fail "global section lacks delay_root"
[ "$(be7000_fstab_get "$D" '@global[0].auto_mount')" = 1 ] || fail "global section lacks auto_mount"
cp "$D/fstab" "$TMP/keep1"
be7000_fstab_ensure "$D" || fail "ensure failed on a file that is fine"
cmp -s "$D/fstab" "$TMP/keep1" || fail "ensure changed a file that already had its global section"

mkdir -p "$TMP/lib2/fstab"
be7000_fstab_ensure "$TMP/lib2" && fail "ensure accepted a directory in place of fstab"
mkdir -p "$TMP/lib3"
ln -s "$TMP/nowhere" "$TMP/lib3/fstab"
be7000_fstab_ensure "$TMP/lib3" && fail "ensure accepted a dangling link in place of fstab"
[ ! -e "$TMP/nowhere" ] || fail "ensure wrote through a dangling link"
be7000_fstab_ensure "" && fail "ensure accepted an empty directory name"

# a value that was set but not committed is not in the file, and does not count
uci -q -c "$D" set fstab.ghost=mount
uci -q -c "$D" set fstab.ghost.target='/overlay'
[ "$(uci -q -c "$D" get fstab.ghost.target)" = /overlay ] || fail "test setup: the pending change is not visible to uci"
be7000_fstab_get "$D" ghost.target >/dev/null && fail "a change that never reached the file counted as written"
be7000_fstab_has "$D" ghost && fail "has saw a section that is not in the file"
be7000_fstab_lacks "$D" ghost || fail "lacks did not see that the section is not in the file"
uci -q -c "$D" revert fstab
be7000_fstab_lacks "$TMP/none" ghost && fail "lacks took a missing file for a file without the section"

t_written() { be7000_fstab_has "$1" "$2" target /overlay enabled 1; }

# a batch that reaches the file
printf "set fstab.one=mount\nset fstab.one.target='/overlay'\nset fstab.one.enabled='1'\ncommit fstab\n" |
	be7000_fstab_batch "$D" t_written one || fail "a good batch was reported as failed"
t_written "$D" one || fail "a good batch is not in the file"

# a batch without a check, and with empty input, leaves the file alone
cp "$D/fstab" "$TMP/keep1"
be7000_fstab_batch "$D" "" </dev/null || fail "an empty batch without a check failed"
be7000_fstab_batch "$D" </dev/null || fail "an empty batch with no check argument failed"
cmp -s "$D/fstab" "$TMP/keep1" || fail "an empty batch changed the file"

# a batch that names a section that is not there: uci says nothing, the check
# does, and the file is as before with nothing left pending
printf "set fstab.two.target='/overlay'\nset fstab.two.enabled='1'\ncommit fstab\n" |
	be7000_fstab_batch "$D" t_written two 2>/dev/null && fail "a batch that wrote nothing was reported as done"
cmp -s "$D/fstab" "$TMP/keep1" || fail "a failed batch left the file changed"
[ -z "$(uci -q -c "$D" changes fstab)" ] || fail "a failed batch left changes pending"

# half of a batch lands, the check fails: the half is taken back
printf "set fstab.three=mount\nset fstab.three.target='/overlay'\ncommit fstab\n" |
	be7000_fstab_batch "$D" t_written three 2>/dev/null && fail "half a batch was reported as done"
cmp -s "$D/fstab" "$TMP/keep1" || fail "half a batch stayed in the file"

# a file that is not there is made first, then written
D2="$TMP/lib4/upper/etc/config"
printf "set fstab.one=mount\nset fstab.one.target='/overlay'\nset fstab.one.enabled='1'\ncommit fstab\n" |
	be7000_fstab_batch "$D2" t_written one || fail "a batch on a missing fstab failed"
t_written "$D2" one || fail "a batch on a missing fstab is not in the file"
[ "$(be7000_fstab_get "$D2" '@global[0]')" = global ] || fail "the new fstab has no global section"

# uci answers success and writes nothing (a full volume): failure, file as before
cp "$D/fstab" "$TMP/keep1"
echo "$D" > "$TMP/uci-drop"
printf "set fstab.four=mount\nset fstab.four.target='/overlay'\nset fstab.four.enabled='1'\ncommit fstab\n" |
	be7000_fstab_batch "$D" t_written four 2>/dev/null && fail "a swallowed batch was reported as done"
: > "$TMP/uci-drop"
cmp -s "$D/fstab" "$TMP/keep1" || fail "a swallowed batch changed the file"

# where the file cannot be made at all
echo "$TMP/lib5/*" > "$TMP/uci-drop"
printf "set fstab.one=mount\ncommit fstab\n" |
	be7000_fstab_batch "$TMP/lib5/etc/config" t_written one 2>/dev/null && fail "a batch was reported as done where fstab cannot get its global section"
: > "$TMP/uci-drop"

# a real volume that is full, when this machine lets the test mount one
FULL="$TMP/full"
mkdir -p "$FULL"
if /bin/mount -t tmpfs -o size=16k tmpfs "$FULL" 2>/dev/null; then
	mkdir -p "$FULL/etc/config"
	be7000_fstab_ensure "$FULL/etc/config" || fail "ensure failed on a small volume that still has room"
	cp "$FULL/etc/config/fstab" "$TMP/keep-full"
	dd if=/dev/zero of="$FULL/fill" bs=1k count=64 2>/dev/null || true
	rc=0
	printf "set fstab.big=mount\nset fstab.big.target='/overlay'\nset fstab.big.enabled='1'\nset fstab.big.options='%s'\ncommit fstab\n" \
		"$(head -c 3000 /dev/zero | tr '\0' x)" |
		be7000_fstab_batch "$FULL/etc/config" t_written big 2>/dev/null || rc=$?
	[ "$rc" != 0 ] || fail "a batch on a full volume was reported as done"
	cmp -s "$FULL/etc/config/fstab" "$TMP/keep-full" || fail "a batch on a full volume left the file changed"
	/bin/umount "$FULL" || fail "test cleanup: cannot unmount the small volume"
	echo "full volume case: checked"
else
	echo "note: no tmpfs mount here, the full volume case was not run"
fi

echo "fstab helpers: OK"

# --- 3. the USB wizard ----------------------------------------------------------

LIVE="$TMP/overlay/upper/etc/config"
echo "$LIVE" > "$TMP/live"

sed -e '/be7000-factory-reset-guard\.sh/d' -e '/be7000-fstab\.sh/d' -e '/^YES=0$/,$d' \
	-e "s# /etc/config# $LIVE#g" \
	-e "s# /rom/# $TMP/rom/#g" \
	-e "s#cp -a /overlay/\\.#cp -a $TMP/overlay/.#" \
	-e "s#/sys/class/ubi/#$TMP/sys/class/ubi/#g" \
	"$ROOT/overlay-files/usr/sbin/be7000-extroot" > "$TMP/extroot-functions"
grep -q ' /etc/config' "$TMP/extroot-functions" && fail "test setup: a live settings path is left in the wizard"
grep -q "cp -a $TMP/overlay/\\." "$TMP/extroot-functions" || fail "test setup: the copy of /overlay was not redirected"
grep -q "$TMP/rom/etc/config/bigoverlay" "$TMP/extroot-functions" || fail "test setup: the image's bigoverlay was not redirected"
grep -q ' /sys/class/ubi' "$TMP/extroot-functions" && fail "test setup: a /sys path is left in the wizard"

. "$ROOT/overlay-files/lib/functions/be7000-factory-reset-guard.sh"
. "$TMP/extroot-functions"

GLOBAL="config global
	option anon_swap '0'
	option anon_mount '0'
	option auto_swap '1'
	option auto_mount '1'
	option delay_root '5'
	option check_fs '0'
"
BIGOVERLAY="config mount 'bigoverlay'
	option target '/overlay'
	option device '/dev/ubi1_1'
	option fstype 'ubifs'
	option options 'rw,noatime'
	option enabled '1'
"

# A router that lives on the settings volume (bigoverlay), a blank disk.
# $1 live fstab: none | plain | bigoverlay   $2 the same for rootfs_data
world() {
	local d
	for d in overlay raw disk cfg rom; do clear_dir "$TMP/$d"; done
	mkdir -p "$LIVE" "$TMP/rom/etc/config" "$TMP/overlay/work"
	printf "config bigoverlay 'main'\n\toption enabled '1'\n" > "$TMP/rom/etc/config/bigoverlay"
	cp "$TMP/rom/etc/config/bigoverlay" "$LIVE/bigoverlay"
	printf "config system\n\toption hostname 'test'\n" > "$LIVE/system"
	case "$1" in
	plain) printf '%s' "$GLOBAL" > "$LIVE/fstab" ;;
	bigoverlay) printf '%s\n%s' "$GLOBAL" "$BIGOVERLAY" > "$LIVE/fstab" ;;
	esac
	case "$2" in
	plain) mkdir -p "$TMP/raw/upper/etc/config"; printf '%s' "$GLOBAL" > "$TMP/raw/upper/etc/config/fstab" ;;
	bigoverlay) mkdir -p "$TMP/raw/upper/etc/config"; printf '%s\n%s' "$GLOBAL" "$BIGOVERLAY" > "$TMP/raw/upper/etc/config/fstab" ;;
	esac
	echo old-data > "$TMP/disk/old-file"
	printf '%s %s\n' /dev/ubi0_2 "$TMP/raw" "$DISK" "$TMP/disk" /dev/ubi1_1 "$TMP/cfg" > "$TMP/devices"
	printf '%s\n' '/dev/ubi1_1 on /overlay type ubifs (rw,noatime)' > "$TMP/mount.out"
	: > "$BE7000_RESET_PROC_MOUNTS"
	printf '%s: UUID="%s" LABEL="be7000_overlay" VERSION="1.0" TYPE="ext4"\n' "$DISK" "$UUID" > "$TMP/block.out"
	: > "$TMP/calls"; : > "$TMP/mounted"; : > "$TMP/uci-drop"
	rm -f "$TMP/mount-fail"
	clear_dir "$TMP/uci-save"
}

# The wizard ends the shell on failure and runs with "set -e", so each run
# gets a shell of its own in which that is in force (it is not on the left of
# "||").
run() {
	set +e
	( set -e; "$@" ) > "$TMP/out" 2>&1
	rc=$?
	set -e
}

use_run() { run cmd_use "$DISK" 1 0; }

no_leftovers() {
	[ ! -s "$TMP/mounted" ] || fail "$1: something stayed mounted: $(cat "$TMP/mounted")"
	[ -z "$(uci -q -c "$LIVE" changes fstab)" ] || fail "$1: changes to the live fstab stayed pending"
}

for case_name in none-none plain-plain bigoverlay-bigoverlay none-bigoverlay bigoverlay-none; do
	world "${case_name%-*}" "${case_name#*-}"
	use_run
	[ "$rc" = 0 ] || fail "use ($case_name) failed: $(cat "$TMP/out")"
	grep -q '^Done\.' "$TMP/out" || fail "use ($case_name) did not say it was done"
	grep -q '^mkfs fstab-present$' "$TMP/calls" || fail "use ($case_name): the disk was erased before the live fstab existed"
	extroot_written "$LIVE" "$UUID" || fail "use ($case_name): the live fstab does not name the disk"
	extroot_written "$TMP/raw/upper/etc/config" "$UUID" || fail "use ($case_name): the fstab in rootfs_data does not name the disk"
	extroot_written "$TMP/disk/upper/etc/config" "$UUID" || fail "use ($case_name): the settings on the disk do not name it"
	[ "$(be7000_config_get "$TMP/disk/upper/etc/config" bigoverlay main.enabled)" = 0 ] || fail "use ($case_name): bigoverlay is on in the settings on the disk"
	[ "$(be7000_config_get "$LIVE" bigoverlay main.enabled)" = 1 ] || fail "use ($case_name): bigoverlay was switched off in the settings in use"
	[ -f "$TMP/disk/upper/etc/config/system" ] || fail "use ($case_name): the settings were not copied to the disk"
	[ -d "$TMP/disk/work" ] || fail "use ($case_name): the disk has no work directory"
	[ ! -e "$TMP/disk/old-file" ] || fail "use ($case_name): test setup, the disk was not erased"
	[ "$(be7000_fstab_get "$TMP/raw/upper/etc/config" '@global[0].delay_root')" = 15 ] || fail "use ($case_name): rootfs_data does not wait for USB"
	if [ "${case_name#*-}" = bigoverlay ]; then
		be7000_fstab_has "$TMP/raw/upper/etc/config" bigoverlay device /dev/ubi1_1 enabled 1 ||
			fail "use ($case_name): the bigoverlay entry in rootfs_data was lost"
	fi
	grep -q '^reboot' "$TMP/calls" && fail "use ($case_name): rebooted without being asked"
	no_leftovers "use ($case_name)"
done

# a longer wait for USB that someone has set stays
world plain plain
uci -q -c "$LIVE" set fstab.@global[0].delay_root='30'
uci -q -c "$LIVE" commit fstab
use_run
[ "$rc" = 0 ] || fail "use (long delay) failed: $(cat "$TMP/out")"
[ "$(be7000_fstab_get "$LIVE" '@global[0].delay_root')" = 30 ] || fail "use shortened a longer delay_root"
[ "$(be7000_fstab_get "$TMP/raw/upper/etc/config" '@global[0].delay_root')" = 30 ] || fail "use did not carry the longer delay_root into rootfs_data"

# --reboot reboots, and only after everything is written
world plain plain
run cmd_use "$DISK" 1 1
[ "$rc" = 0 ] || fail "use --reboot failed: $(cat "$TMP/out")"
grep -q '^reboot' "$TMP/calls" || fail "use --reboot did not reboot"

# without --yes nothing happens
world plain plain
cp "$LIVE/fstab" "$TMP/keep1"
run cmd_use "$DISK" 0 0
[ "$rc" != 0 ] || fail "use without --yes went ahead"
grep -q '^mkfs' "$TMP/calls" && fail "use without --yes erased the disk"
cmp -s "$LIVE/fstab" "$TMP/keep1" || fail "use without --yes changed fstab"

# The live fstab cannot be made: stop before the disk is erased.
world none plain
mkdir -p "$LIVE/fstab"
use_run
[ "$rc" != 0 ] || fail "use went ahead although the live fstab cannot be made"
grep -q '^mkfs' "$TMP/calls" && fail "use erased the disk although the live fstab cannot be made"
grep -q 'nothing was changed' "$TMP/out" || fail "use did not say that nothing was changed: $(cat "$TMP/out")"
[ -e "$TMP/disk/old-file" ] || fail "the disk lost its data although use stopped early"
rmdir "$LIVE/fstab"

# rootfs_data cannot take an fstab: stop before the disk is erased.
world plain none
echo '*/extroot-vol.*/upper/etc/config' > "$TMP/uci-drop"
use_run
[ "$rc" != 0 ] || fail "use went ahead although rootfs_data takes no fstab"
grep -q '^mkfs' "$TMP/calls" && fail "use erased the disk although rootfs_data takes no fstab"
grep -q 'nothing was changed' "$TMP/out" || fail "use did not say that nothing was changed: $(cat "$TMP/out")"
[ -e "$TMP/disk/old-file" ] || fail "the disk lost its data although use stopped early"
[ ! -e "$TMP/raw/upper/etc/config/fstab" ] || fail "an empty fstab stayed in rootfs_data after use stopped early"
no_leftovers "use (rootfs_data takes no fstab)"

# rootfs_data cannot be mounted: stop before the disk is erased.
world plain plain
echo /dev/ubi0_2 > "$TMP/mount-fail"
use_run
[ "$rc" != 0 ] || fail "use went ahead although rootfs_data cannot be looked into"
grep -q '^mkfs' "$TMP/calls" && fail "use erased the disk although rootfs_data cannot be looked into"

# The cases below fail after the disk is erased. The settings must be exactly
# as before, and the answer must not be "Done".
after_format_failure() {
	local what="$1"
	[ "$rc" != 0 ] || fail "use ($what) was reported as done: $(cat "$TMP/out")"
	grep -q '^Done\.' "$TMP/out" && fail "use ($what) said Done"
	grep -q 'settings are as they were before' "$TMP/out" || fail "use ($what) did not say the settings are unchanged: $(cat "$TMP/out")"
	cmp -s "$LIVE/fstab" "$TMP/keep-live" || fail "use ($what) left the live fstab changed"
	if [ -f "$TMP/keep-raw" ]; then
		cmp -s "$TMP/raw/upper/etc/config/fstab" "$TMP/keep-raw" || fail "use ($what) left the fstab in rootfs_data changed"
	fi
	be7000_fstab_lacks "$TMP/raw/upper/etc/config" extroot || fail "use ($what) left an extroot entry in rootfs_data"
	[ "$(be7000_config_get "$LIVE" bigoverlay main.enabled)" = 1 ] || fail "use ($what) switched bigoverlay off in the settings in use"
	grep -q '^reboot' "$TMP/calls" && fail "use ($what) rebooted"
	no_leftovers "use ($what)"
	[ ! -e "/tmp/extroot-fstab-before.$$" ] || fail "use ($what) left its copy of fstab in /tmp"
}

# uci answers success for the entry in rootfs_data and writes nothing
world bigoverlay bigoverlay
cp "$LIVE/fstab" "$TMP/keep-live"; cp "$TMP/raw/upper/etc/config/fstab" "$TMP/keep-raw"
echo '*/extroot-vol.*/upper/etc/config' > "$TMP/uci-drop"
use_run
after_format_failure "rootfs_data write swallowed"

# the same for the live fstab
world bigoverlay bigoverlay
cp "$LIVE/fstab" "$TMP/keep-live"; cp "$TMP/raw/upper/etc/config/fstab" "$TMP/keep-raw"
echo "$LIVE" > "$TMP/uci-drop"
use_run
after_format_failure "live write swallowed"

# the disk has no UUID to go by
world bigoverlay bigoverlay
cp "$LIVE/fstab" "$TMP/keep-live"; cp "$TMP/raw/upper/etc/config/fstab" "$TMP/keep-raw"
: > "$TMP/block.out"
use_run
after_format_failure "no UUID"

# the disk does not mount after the format
world bigoverlay bigoverlay
cp "$LIVE/fstab" "$TMP/keep-live"; cp "$TMP/raw/upper/etc/config/fstab" "$TMP/keep-raw"
echo "$DISK" > "$TMP/mount-fail"
use_run
[ "$rc" != 0 ] || fail "use was reported as done although the disk does not mount"
grep -q 'were not changed' "$TMP/out" || fail "use (disk does not mount) did not say the settings are unchanged: $(cat "$TMP/out")"
cmp -s "$LIVE/fstab" "$TMP/keep-live" || fail "use (disk does not mount) left the live fstab changed"
cmp -s "$TMP/raw/upper/etc/config/fstab" "$TMP/keep-raw" || fail "use (disk does not mount) changed rootfs_data"
[ ! -e "/tmp/extroot.$$" ] || fail "use (disk does not mount) left its mount point in /tmp"

# a factory reset waits: nothing is touched
world bigoverlay bigoverlay
mkdir -p "$TMP/raw/.be7000_factory_reset"
use_run
[ "$rc" != 0 ] || fail "use went ahead while a factory reset waits"
grep -q '^mkfs' "$TMP/calls" && fail "use erased the disk while a factory reset waits"

# the router runs from the slot's own storage: the live fstab is the one in
# rootfs_data, and one write serves both
world none none
printf '%s\n' '/dev/ubi0_2 on /overlay type ubifs (rw,noatime)' > "$TMP/mount.out"
printf '%s %s ubifs rw,noatime 0 0\n' /dev/ubi0_2 "$TMP/overlay" > "$BE7000_RESET_PROC_MOUNTS"
use_run
[ "$rc" = 0 ] || fail "use (from the slot's storage) failed: $(cat "$TMP/out")"
extroot_written "$LIVE" "$UUID" || fail "use (from the slot's storage): fstab does not name the disk"
extroot_written "$TMP/disk/upper/etc/config" "$UUID" || fail "use (from the slot's storage): the settings on the disk do not name it"
grep -q '^mount /dev/ubi0_2' "$TMP/calls" && fail "use (from the slot's storage) mounted rootfs_data a second time"

echo "USB wizard, use: OK"

# revert takes the entry out everywhere
world bigoverlay bigoverlay
use_run
[ "$rc" = 0 ] || fail "revert setup: use failed"
mkdir -p "$TMP/cfg/upper/etc/config"
cp "$LIVE/fstab" "$TMP/cfg/upper/etc/config/fstab"
# the router now runs from the disk
printf '%s\n' "$DISK on /overlay type ext4 (rw,noatime)" > "$TMP/mount.out"
run cmd_revert 1 0
[ "$rc" = 0 ] || fail "revert failed: $(cat "$TMP/out")"
be7000_fstab_lacks "$LIVE" extroot || fail "revert left the entry in the live fstab"
be7000_fstab_lacks "$TMP/raw/upper/etc/config" extroot || fail "revert left the entry in rootfs_data"
be7000_fstab_lacks "$TMP/cfg/upper/etc/config" extroot || fail "revert left the entry on the settings volume"
be7000_fstab_has "$TMP/raw/upper/etc/config" bigoverlay device /dev/ubi1_1 || fail "revert removed more than the extroot entry"
no_leftovers revert

# revert when rootfs_data does not take the change: the live fstab stays too
world bigoverlay bigoverlay
use_run
printf '%s\n' "$DISK on /overlay type ext4 (rw,noatime)" > "$TMP/mount.out"
cp "$LIVE/fstab" "$TMP/keep-live"
echo '*/extroot-vol.*/upper/etc/config' > "$TMP/uci-drop"
run cmd_revert 1 0
[ "$rc" != 0 ] || fail "revert was reported as done although rootfs_data kept the entry"
grep -q 'nothing was changed' "$TMP/out" || fail "revert did not say that nothing was changed: $(cat "$TMP/out")"
cmp -s "$LIVE/fstab" "$TMP/keep-live" || fail "a failed revert changed the live fstab"
extroot_written "$TMP/raw/upper/etc/config" "$UUID" || fail "a failed revert lost the entry in rootfs_data"

# a settings volume that never had an fstab does not get one from revert
world bigoverlay bigoverlay
use_run
printf '%s\n' "$DISK on /overlay type ext4 (rw,noatime)" > "$TMP/mount.out"
run cmd_revert 1 0
[ "$rc" = 0 ] || fail "revert (settings volume without fstab) failed: $(cat "$TMP/out")"
[ ! -e "$TMP/cfg/upper" ] || fail "revert made an upper directory on a volume that had none"

echo "USB wizard, revert: OK"

# boot-sync after a firmware update: rootfs_data is new, the live settings name
# the disk, the disk is not plugged in
world bigoverlay none
extroot_batch "$UUID" 5 | be7000_fstab_batch "$LIVE" extroot_written "$UUID" || fail "boot-sync setup"
: > "$TMP/block.out"
cmd_boot_sync
extroot_written "$TMP/raw/upper/etc/config" "$UUID" || fail "boot-sync did not put the entry back into a new rootfs_data"
grep -q '^reboot' "$TMP/calls" && fail "boot-sync rebooted for a disk that is not there"
no_leftovers boot-sync

# the same when the entry cannot be written: no reboot to a disk rootfs_data
# does not name (it would be asked for again on every boot)
world bigoverlay none
extroot_batch "$UUID" 5 | be7000_fstab_batch "$LIVE" extroot_written "$UUID" || fail "boot-sync setup"
echo '*/extroot-sync.*/upper/etc/config' > "$TMP/uci-drop"
cmd_boot_sync
: > "$TMP/uci-drop"
grep -q '^reboot' "$TMP/calls" && fail "boot-sync rebooted although the entry was not written"
grep -q 'could not put the extroot entry' "$TMP/calls" || fail "boot-sync did not log that the entry was not written"
[ ! -e "$TMP/raw/upper/etc/config/fstab" ] || fail "boot-sync left an fstab it could not fill in rootfs_data"
no_leftovers "boot-sync (write swallowed)"

# nothing to do: nothing is written
world bigoverlay bigoverlay
tree_sum "$TMP/raw" > "$TMP/sum1"
cmd_boot_sync
tree_sum "$TMP/raw" > "$TMP/sum2"
cmp -s "$TMP/sum1" "$TMP/sum2" || fail "boot-sync changed rootfs_data without a reason"

echo "USB wizard, boot-sync: OK"

# --- 4. the checks of the slot storage and bigoverlay writers ------------------

# in a shell of its own: the slot tool has functions with the wizard's names
(
sed -e '/be7000-factory-reset-guard\.sh/d' -e '/be7000-fstab\.sh/d' -e '/^case "\$1" in$/,$d' \
	"$ROOT/overlay-files/usr/libexec/be7000-slots" > "$TMP/slot-functions"
. "$TMP/slot-functions"

D3="$TMP/slots/etc/config"
fstab_slotstorage_batch | be7000_fstab_batch "$D3" slotstorage_written || fail "the slot storage entry was not accepted on a new fstab"
slotstorage_written "$D3" || fail "the slot storage entry is not in the file"
bigoverlay_written "$D3" && fail "the bigoverlay check holds while slot storage is configured"
fstab_bigoverlay_batch | be7000_fstab_batch "$D3" bigoverlay_written || fail "the way back to bigoverlay was not accepted"
be7000_fstab_lacks "$D3" slotstorage || fail "the slot storage entry stayed after the way back"
be7000_fstab_has "$D3" bigoverlay device /dev/ubi1_1 enabled 1 || fail "bigoverlay is not in the file after the way back"
cp "$D3/fstab" "$TMP/keep1"
echo "$D3" > "$TMP/uci-drop"
fstab_slotstorage_batch | be7000_fstab_batch "$D3" slotstorage_written 2>/dev/null && fail "a swallowed slot storage entry was reported as written"
: > "$TMP/uci-drop"
cmp -s "$D3/fstab" "$TMP/keep1" || fail "a swallowed slot storage entry changed the file"

sed -n '/^bigoverlay_names()/,/^}/p' "$ROOT/overlay-files/etc/init.d/bigoverlay" > "$TMP/bigoverlay-check"
grep -q be7000_fstab_get "$TMP/bigoverlay-check" || fail "test setup: bigoverlay_names was not found"
. "$TMP/bigoverlay-check"
bigoverlay_names "$D3" /dev/ubi1_1 || fail "bigoverlay_names does not see the device in the file"
bigoverlay_names "$D3" /dev/ubi1_0 && fail "bigoverlay_names accepts another device"
bigoverlay_names "$TMP/none" /dev/ubi1_1 && fail "bigoverlay_names accepts a missing file"
# the answer of this shell is not the answer of the last check
:

)
echo "slot storage and bigoverlay checks: OK"

# --- 5. cancelling a factory reset (be7000-reset) --------------------------------

TOOL="$ROOT/overlay-files/usr/libexec/be7000-reset"
BE7000_RESET_SYS_BLOCK="$TMP/sys/block"
BE7000_RESET_OVERLAY="$TMP/overlay"
BE7000_RESET_CONFIG="$LIVE"
BE7000_RESET_ROM_CONFIG="$TMP/rom/etc/config"
export BE7000_RESET_SYS_BLOCK BE7000_RESET_OVERLAY BE7000_RESET_CONFIG BE7000_RESET_ROM_CONFIG
mkdir -p "$TMP/sys/block"

TOKEN=4b1d6a2c9e8f
JOBFSTAB="$GLOBAL
config mount 'extroot'
	option target '/overlay'
	option uuid '$UUID'
	option fstype 'ext4'
	option options 'rw,noatime'
	option enabled '1'
"

# $1 directory that is rootfs_data, $2 device, $3 fstype, $4 uuid or ""
make_job() {
	local j="$1/.be7000_factory_reset"
	mkdir -p "$j/config"
	echo 1 > "$j/version"
	echo "$2" > "$j/device"
	echo "$3" > "$j/fstype"
	echo "$TOKEN" > "$j/token"
	[ -z "$4" ] || echo "$4" > "$j/uuid"
	printf '%s' "$JOBFSTAB" > "$j/config/fstab"
	printf "config bigoverlay 'main'\n\toption enabled '0'\n" > "$j/config/bigoverlay"
}

# The stuck state: the disk is gone, the router came up on the slot's own
# storage (rootfs_data is /overlay), the hook has left its reason.
stuck_world() {
	world none none
	printf '%s %s ubifs rw,noatime 0 0\n' /dev/ubi0_2 "$TMP/overlay" > "$BE7000_RESET_PROC_MOUNTS"
	make_job "$TMP/overlay" /dev/sda1 ext4 "$UUID"
	echo absent > "$TMP/overlay/.be7000_factory_reset/why"
	: > "$TMP/overlay/.be7000_factory_reset/extroot-blocked"
	: > "$TMP/block.out"
	rm -f "$TMP/sys/block"/sd* 2>/dev/null || true
}

has() { grep -q -- "$1" "$TMP/out" || fail "$2: expected $1 in: $(cat "$TMP/out")"; }

# no job
world plain plain
sh "$TOOL" status > "$TMP/out" || fail "status failed without a job"
[ "$(cat "$TMP/out")" = '{"pending":false}' ] || fail "status without a job: $(cat "$TMP/out")"
no_leftovers "status without a job"
rc=0; sh "$TOOL" cancel > "$TMP/out" || rc=$?
[ "$rc" != 0 ] || fail "cancel without a job was reported as done"
has '"ok":false' "cancel without a job"
tree_sum "$TMP/raw" > "$TMP/sum1"

# status in the stuck state
stuck_world
sh "$TOOL" status > "$TMP/out" || fail "status failed"
for want in '"pending":true' '"kind":"disk"' '"device":"/dev/sda1"' "\"uuid\":\"$UUID\"" '"fstype":"ext4"' \
	'"why":"absent"' '"tried":true' '"inslot":true' '"present":false' '"now":""' '"disks":false' '"cancellable":true'; do
	has "$want" "status (stuck)"
done

# the disk is back under another name
printf '/dev/sdb1: UUID="%s" LABEL="be7000_overlay" TYPE="ext4"\n' "$UUID" > "$TMP/block.out"
: > "$TMP/sys/block/sdb"
sh "$TOOL" status > "$TMP/out"
has '"present":true' "status (disk back)"; has '"now":"/dev/sdb1"' "status (disk back)"; has '"disks":true' "status (disk back)"

# another disk is plugged in: not the one the reset waits for
printf '/dev/sdb1: UUID="11111111-2222-3333-4444-555555555555" TYPE="ext4"\n' > "$TMP/block.out"
sh "$TOOL" status > "$TMP/out"
has '"present":false' "status (other disk)"; has '"disks":true' "status (other disk)"

# job fields are data: a strange reason or device is not passed on
stuck_world
printf 'x"; reboot; "\n' > "$TMP/overlay/.be7000_factory_reset/why"
printf '/dev/sd a1\n' > "$TMP/overlay/.be7000_factory_reset/device"
sh "$TOOL" status > "$TMP/out"
has '"why":""' "status (strange fields)"; has '"device":""' "status (strange fields)"; has '"kind":"unknown"' "status (strange fields)"
has '"cancellable":false' "status (strange fields)"
grep -q '^reboot' "$TMP/calls" && fail "status ran something from a job field"

# cancel in the stuck state, bigoverlay on in the settings in use
stuck_world
tree_sum "$TMP/disk" > "$TMP/sum-disk"
find "$TMP/overlay/.be7000_factory_reset" | sort | sed "s#^$TMP/overlay/.be7000_factory_reset##" > "$TMP/job-files"
sh "$TOOL" cancel > "$TMP/out" || fail "cancel failed: $(cat "$TMP/out")"
[ "$(cat "$TMP/out")" = '{"ok":true,"state":"internal"}' ] || fail "cancel (stuck) answered: $(cat "$TMP/out")"
[ "$(be7000_config_get "$LIVE" bigoverlay main.enabled)" = 0 ] || fail "cancel left bigoverlay on: the next boot would go back to the old settings volume"
[ ! -e "$TMP/overlay/.be7000_factory_reset" ] || fail "cancel left the job in place"
[ -d "$TMP/overlay/.be7000_factory_reset_cancelled" ] || fail "cancel did not keep the job"
find "$TMP/overlay/.be7000_factory_reset_cancelled" | sort | sed "s#^$TMP/overlay/.be7000_factory_reset_cancelled##" > "$TMP/job-files2"
cmp -s "$TMP/job-files" "$TMP/job-files2" || fail "the kept job lost files"
[ ! -e "$LIVE/fstab" ] || fail "cancel (stuck) made an fstab: the router would leave the slot's storage"
tree_sum "$TMP/disk" > "$TMP/sum2"
cmp -s "$TMP/sum-disk" "$TMP/sum2" || fail "cancel touched the disk"
grep -q "^mount $DISK" "$TMP/calls" && fail "cancel mounted the disk"
[ -f "$LIVE/system" ] || fail "cancel lost settings"
sh "$TOOL" status > "$TMP/out"
[ "$(cat "$TMP/out")" = '{"pending":false}' ] || fail "status after cancel: $(cat "$TMP/out")"
be7000_factory_reset_pending && fail "the writers still see a reset after cancel"
grep -q '^logger.*cancelled' "$TMP/calls" || fail "cancel left nothing in the log"
no_leftovers "cancel (stuck)"

# the same on a router whose settings have no bigoverlay file yet
stuck_world
rm -f "$LIVE/bigoverlay"
sh "$TOOL" cancel > "$TMP/out" || fail "cancel (no bigoverlay settings) failed: $(cat "$TMP/out")"
[ "$(be7000_config_get "$LIVE" bigoverlay main.enabled)" = 0 ] || fail "cancel (no bigoverlay settings) did not switch it off"

# bigoverlay cannot be switched off: nothing changes
stuck_world
rm -f "$LIVE/bigoverlay" "$TMP/rom/etc/config/bigoverlay"
tree_sum "$TMP/overlay" > "$TMP/sum1"
rc=0; sh "$TOOL" cancel > "$TMP/out" || rc=$?
[ "$rc" != 0 ] || fail "cancel was reported as done although bigoverlay stays on"
has '"ok":false' "cancel (bigoverlay stays on)"
tree_sum "$TMP/overlay" > "$TMP/sum2"
cmp -s "$TMP/sum1" "$TMP/sum2" || fail "a refused cancel changed something"

# a job set aside earlier makes room
stuck_world
mkdir -p "$TMP/overlay/.be7000_factory_reset_cancelled"
echo older > "$TMP/overlay/.be7000_factory_reset_cancelled/device"
sh "$TOOL" cancel > "$TMP/out" || fail "cancel (older kept job) failed: $(cat "$TMP/out")"
[ "$(cat "$TMP/overlay/.be7000_factory_reset_cancelled/device")" = /dev/sda1 ] || fail "the kept job is not the one that was cancelled"
[ ! -e "$TMP/overlay/.be7000_factory_reset" ] || fail "cancel (older kept job) left the job in place"

# a reset of the built-in storage is not cancelled here
stuck_world
echo /dev/ubi1_1 > "$TMP/overlay/.be7000_factory_reset/device"
echo ubifs > "$TMP/overlay/.be7000_factory_reset/fstype"
rm -f "$TMP/overlay/.be7000_factory_reset/uuid"
echo write > "$TMP/overlay/.be7000_factory_reset/why"
sh "$TOOL" status > "$TMP/out"
has '"kind":"internal"' "status (built-in)"; has '"cancellable":false' "status (built-in)"; has '"why":"write"' "status (built-in)"
tree_sum "$TMP/overlay" > "$TMP/sum1"
rc=0; sh "$TOOL" cancel > "$TMP/out" || rc=$?
[ "$rc" != 0 ] || fail "a reset of the built-in storage was cancelled"
tree_sum "$TMP/overlay" > "$TMP/sum2"
cmp -s "$TMP/sum1" "$TMP/sum2" || fail "a refused cancel (built-in) changed something"

# a link in place of the job is not followed
stuck_world
mv "$TMP/overlay/.be7000_factory_reset" "$TMP/elsewhere"
ln -s "$TMP/elsewhere" "$TMP/overlay/.be7000_factory_reset"
rc=0; sh "$TOOL" cancel > "$TMP/out" || rc=$?
[ "$rc" != 0 ] || fail "cancel followed a link in place of the job"
[ -f "$TMP/elsewhere/device" ] || fail "cancel moved what a link pointed at"
[ "$(be7000_config_get "$LIVE" bigoverlay main.enabled)" = 1 ] || fail "cancel changed bigoverlay for a job that is a link"

# The reset was asked for and the router has not restarted: it still runs from
# the disk (which the kernel now calls sdb1), rootfs_data is not mounted.
fresh_world() {
	world none none
	printf '/dev/sdb1 %s ext4 rw,noatime 0 0\n' "$TMP/overlay" > "$BE7000_RESET_PROC_MOUNTS"
	printf '/dev/sdb1: UUID="%s" LABEL="be7000_overlay" TYPE="ext4"\n' "$UUID" > "$TMP/block.out"
	make_job "$TMP/raw" /dev/sda1 ext4 "$UUID"
	echo "$TOKEN" > "$TMP/overlay/.be7000_factory_reset_token"
	printf '%s' "$JOBFSTAB" > "$LIVE/fstab"
}

fresh_world
sh "$TOOL" status > "$TMP/out"
for want in '"pending":true' '"inslot":false' '"tried":false' '"present":true' '"now":"/dev/sdb1"' '"why":""' '"cancellable":true'; do
	has "$want" "status (not restarted)"
done
no_leftovers "status (not restarted)"

sh "$TOOL" cancel > "$TMP/out" || fail "cancel (not restarted) failed: $(cat "$TMP/out")"
[ "$(cat "$TMP/out")" = '{"ok":true,"state":"unscheduled"}' ] || fail "cancel (not restarted) answered: $(cat "$TMP/out")"
cmp -s "$TMP/raw/upper/etc/config/fstab" "$TMP/raw/.be7000_factory_reset_cancelled/config/fstab" ||
	fail "cancel (not restarted) did not put fstab back into rootfs_data"
be7000_fstab_has "$TMP/raw/upper/etc/config" extroot target /overlay uuid "$UUID" enabled 1 || fail "the fstab put back does not name the disk"
[ ! -e "$TMP/overlay/.be7000_factory_reset_token" ] || fail "cancel (not restarted) left the token on the disk"
[ ! -e "$TMP/raw/.be7000_factory_reset" ] || fail "cancel (not restarted) left the job in place"
[ "$(be7000_config_get "$LIVE" bigoverlay main.enabled)" = 1 ] || fail "cancel (not restarted) changed bigoverlay in the settings in use"
no_leftovers "cancel (not restarted)"

# the copy the hook saved goes back first
fresh_world
printf '%s\n%s' "$JOBFSTAB" "$BIGOVERLAY" > "$TMP/raw/.be7000_factory_reset/rootfs-fstab.saved"
sh "$TOOL" cancel > "$TMP/out" || fail "cancel (saved fstab) failed: $(cat "$TMP/out")"
be7000_fstab_has "$TMP/raw/upper/etc/config" bigoverlay device /dev/ubi1_1 || fail "cancel did not use the fstab the hook saved"

# an fstab that is already there stays as it is
fresh_world
mkdir -p "$TMP/raw/upper/etc/config"
printf '%s' "$GLOBAL" > "$TMP/raw/upper/etc/config/fstab"
# (the guard takes it away while a job waits; put it there behind its back)
sh "$TOOL" cancel > "$TMP/out" || fail "cancel (fstab present) failed: $(cat "$TMP/out")"
[ "$(cat "$TMP/raw/upper/etc/config/fstab")" = "$(printf '%s' "$GLOBAL")" ] || fail "cancel replaced an fstab that was there"

# a token that is not the job's stays
fresh_world
echo someone-elses > "$TMP/overlay/.be7000_factory_reset_token"
sh "$TOOL" cancel > "$TMP/out" || fail "cancel (other token) failed: $(cat "$TMP/out")"
[ "$(cat "$TMP/overlay/.be7000_factory_reset_token")" = someone-elses ] || fail "cancel removed a token that is not the job's"

# /overlay is on something else than the disk the job names: hands off
fresh_world
printf '/dev/sdc1 %s ext4 rw,noatime 0 0\n' "$TMP/overlay" > "$BE7000_RESET_PROC_MOUNTS"
tree_sum "$TMP/raw" > "$TMP/sum1"
rc=0; sh "$TOOL" cancel > "$TMP/out" || rc=$?
[ "$rc" != 0 ] || fail "cancel went ahead although /overlay is on another device"
has 'restart the router first' "cancel (other device)"
tree_sum "$TMP/raw" > "$TMP/sum2"
cmp -s "$TMP/sum1" "$TMP/sum2" || fail "a refused cancel (other device) changed rootfs_data"
[ -e "$TMP/overlay/.be7000_factory_reset_token" ] || fail "a refused cancel (other device) removed the token"

# no fstab to put back: hands off
fresh_world
rm -f "$TMP/raw/.be7000_factory_reset/config/fstab"
rc=0; sh "$TOOL" cancel > "$TMP/out" || rc=$?
[ "$rc" != 0 ] || fail "cancel went ahead with no fstab to put back"
[ -d "$TMP/raw/.be7000_factory_reset" ] || fail "a refused cancel (no fstab) removed the job"

# rootfs_data cannot be looked into
fresh_world
echo /dev/ubi0_2 > "$TMP/mount-fail"
sh "$TOOL" status > "$TMP/out"
has '"pending":false' "status (rootfs_data closed)"; has 'cannot look into rootfs_data' "status (rootfs_data closed)"
rc=0; sh "$TOOL" cancel > "$TMP/out" || rc=$?
[ "$rc" != 0 ] || fail "cancel was reported as done without rootfs_data"

echo "be7000-reset: OK"
echo "storage fstab tests: OK"
