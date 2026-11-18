#!/bin/sh


set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/be7000-factory-reset-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

assert_eq() {
	[ "$1" = "$2" ] || fail "$3: expected '$2', got '$1'"
}

assert_file() {
	[ -f "$1" ] || fail "$2: missing $1"
}

assert_absent() {
	[ ! -e "$1" ] && [ ! -L "$1" ] || fail "$2: unexpected $1"
}

clear_dir() {
	local d="$1" p
	mkdir -p "$d"
	for p in "$d"/* "$d"/.[!.]* "$d"/..?*; do
		[ -e "$p" ] || [ -L "$p" ] || continue
		rm -rf "$p"
	done
}

copy_tree() {
	clear_dir "$2"
	cp -a "$1"/. "$2"/
}

# Source an exact copy without its final entry-point call. This keeps the
# installed script free of a test-only environment switch that could disable
# a real reset.
sed '$d' "$ROOT/overlay-files/sbin/firstboot" > "$TMP/firstboot-functions"
. "$TMP/firstboot-functions"

logger() { :; }
sync() {
	case "${MOCK_FAIL_CONTROL:-}" in quarantine_sync|blocked_sync) return 1 ;; esac
	:
}
sleep() { :; }
reboot() { echo reboot >> "$MOCK_CALLS"; }

mount() {
	local dest="" a backing
	printf '%s\n' "$*" >> "$MOCK_MOUNTS"
	for a in "$@"; do dest="$a"; done
	case "$dest" in
	*/rd|*/rootfs_data)
		backing="$MOCK_RD_BACKING"
		MOCK_RD_MOUNT="$dest"
		;;
	*/target)
		[ "${MOCK_FAIL_TARGET_MOUNT:-0}" = 0 ] || return 1
		backing="$MOCK_TARGET_BACKING"
		MOCK_TARGET_MOUNT="$dest"
		;;
	*) fail "unexpected mount target $dest" ;;
	esac
	copy_tree "$backing" "$dest"
}

umount() {
	local dest="$1"
	case "$dest" in
	"${MOCK_RD_MOUNT:-__never__}")
		[ "${MOCK_FAIL_RD_UMOUNT:-0}" = 0 ] || return 1
		copy_tree "$dest" "$MOCK_RD_BACKING"
		clear_dir "$dest"
		;;
	"${MOCK_TARGET_MOUNT:-__never__}")
		[ "${MOCK_FAIL_TARGET_UMOUNT:-0}" = 0 ] || return 1
		copy_tree "$dest" "$MOCK_TARGET_BACKING"
		clear_dir "$dest"
		;;
	*) fail "unexpected umount target $dest" ;;
	esac
}

setup_schedule_case() {
	local name="$1"
	S="$TMP/schedule-$name"
	mkdir -p "$S/sys/class/ubi/ubi0_2" "$S/overlay/upper/etc/config" \
		"$S/overlay/work/work" "$S/etc/config" "$S/tmp" "$S/rd"
	printf '%s\n' rootfs_data > "$S/sys/class/ubi/ubi0_2/name"
	printf '%s\n' '/dev/ubi1_1 /overlay ubifs rw,noatime 0 0' > "$S/proc.mounts"
	printf '%s\n' old-upper > "$S/overlay/upper/etc/config/old"
	printf '%s\n' old-work > "$S/overlay/work/work/state"
	printf '%s\n' fstab-kept > "$S/etc/config/fstab"
	printf '%s\n' bigoverlay-kept > "$S/etc/config/bigoverlay"
	: > "$S/calls"
	: > "$S/mounts"

	FB_PROC_MOUNTS="$S/proc.mounts"
	FB_SYS_UBI="$S/sys/class/ubi"
	FB_OVERLAY="$S/overlay"
	FB_CONFIG="$S/etc/config"
	FB_TMPDIR="$S/tmp"
	MOCK_RD_BACKING="$S/rd"
	MOCK_TARGET_BACKING="$S/target-unused"
	MOCK_RD_MOUNT=
	MOCK_TARGET_MOUNT=
	MOCK_CALLS="$S/calls"
	MOCK_MOUNTS="$S/mount-calls"
	MOCK_FAIL_TARGET_MOUNT=0
	MOCK_FAIL_TARGET_UMOUNT=0
	MOCK_FAIL_RD_UMOUNT=0
}

# rootfs_data keeps the exact upstream delegation contract. The absolute path
# makes it deliberately static here; external scheduling is exercised below.
grep -F 'exec /sbin/factoryreset "$@"' "$ROOT/overlay-files/sbin/firstboot" >/dev/null ||
	fail "ordinary rootfs_data no longer delegates all arguments"

setup_schedule_case declined
if printf '%s\n' n | (be7000_firstboot_main) >/dev/null 2>&1; then
	fail "interactive reset accepted a negative answer"
fi
assert_absent "$S/rd/$JOB" "declined reset job"
assert_absent "$S/overlay/$MARK" "declined reset marker"
assert_eq "$(cat "$S/overlay/upper/etc/config/old")" old-upper "declined reset changed upper"
assert_eq "$(cat "$S/overlay/work/work/state")" old-work "declined reset changed work"

# block must not be asked about a UBI volume: its name does not change.
block() { echo block >> "$MOCK_CALLS"; printf '%s\n' "${MOCK_BLOCK_INFO:-}"; }

setup_schedule_case no_reboot
(be7000_firstboot_main -y)
assert_absent "$S/rd/$JOB/uuid" "UUID recorded for a UBI volume"
assert_eq "$(cat "$S/rd/$JOB/device")" /dev/ubi1_1 "scheduled device"
assert_eq "$(cat "$S/rd/$JOB/fstype")" ubifs "scheduled filesystem"
assert_eq "$(cat "$S/rd/$JOB/keep")" 0 "scheduled keep flag"
token=$(cat "$S/rd/$JOB/token")
token_valid "$token" || fail "scheduled token is invalid"
assert_eq "$(cat "$S/overlay/$MARK")" "$token" "target token"
cmp -s "$S/etc/config/fstab" "$S/rd/$JOB/config/fstab" || fail "fstab was not preserved"
cmp -s "$S/etc/config/bigoverlay" "$S/rd/$JOB/config/bigoverlay" || fail "bigoverlay was not preserved"
assert_eq "$(cat "$S/overlay/upper/etc/config/old")" old-upper "active upper changed while scheduling"
assert_eq "$(cat "$S/overlay/work/work/state")" old-work "active work changed while scheduling"
[ ! -s "$S/calls" ] || fail "non-r scheduling rebooted"

setup_schedule_case reboot_keep
(be7000_firstboot_main -y -r -k)
assert_eq "$(cat "$S/rd/$JOB/keep")" 1 "scheduled -k flag"
assert_eq "$(cat "$S/calls")" reboot "-r reboot"

# A USB disk goes into the job with the UUID of its filesystem next to the
# name it has on this boot.
setup_schedule_case usb_uuid
printf '%s\n' '/dev/sda1 /overlay ext4 rw,noatime 0 0' > "$S/proc.mounts"
MOCK_BLOCK_INFO='/dev/sda1: UUID="0f3c5d1e-AAAA-bbbb-cccc-1234567890ab" LABEL="be7000_overlay" VERSION="1.0" MOUNT="/overlay" TYPE="ext4"'
(be7000_firstboot_main -y)
assert_eq "$(cat "$S/rd/$JOB/device")" /dev/sda1 "scheduled USB device"
assert_eq "$(cat "$S/rd/$JOB/fstype")" ext4 "scheduled USB filesystem"
assert_eq "$(cat "$S/rd/$JOB/uuid")" 0f3c5d1e-AAAA-bbbb-cccc-1234567890ab "scheduled USB UUID"
assert_eq "$(wc -l < "$S/rd/$JOB/uuid" | tr -d '[:space:]')" 1 "UUID field is one line"

# A filesystem that tells no UUID, or something that is not one, is scheduled
# by name alone.
setup_schedule_case usb_no_uuid
printf '%s\n' '/dev/sda1 /overlay ext4 rw,noatime 0 0' > "$S/proc.mounts"
MOCK_BLOCK_INFO=
(be7000_firstboot_main -y)
assert_file "$S/rd/$JOB/token" "USB without UUID was not scheduled"
assert_absent "$S/rd/$JOB/uuid" "empty UUID recorded"
setup_schedule_case usb_bad_uuid
printf '%s\n' '/dev/sda1 /overlay ext4 rw,noatime 0 0' > "$S/proc.mounts"
MOCK_BLOCK_INFO='/dev/sda1: UUID="../../etc" TYPE="ext4"'
(be7000_firstboot_main -y)
assert_file "$S/rd/$JOB/token" "USB with a malformed UUID was not scheduled"
assert_absent "$S/rd/$JOB/uuid" "malformed UUID recorded"
MOCK_BLOCK_INFO=

# An interrupted cleanup of an already completed job must not block a new one.
setup_schedule_case stale_done
mkdir -p "$S/rd/.be7000_factory_reset_done.old/config"
printf '%s\n' partial > "$S/rd/.be7000_factory_reset_done.old/config/remnant"
(be7000_firstboot_main -y)
assert_file "$S/rd/$JOB/token" "stale completed state blocked scheduling"

# A failed rootfs_data unmount must leave the mountpoint and its contents
# intact. In particular, cleanup must never recurse through that mountpoint.
setup_schedule_case rd_umount_failure
printf '%s\n' rootfs-data-survives > "$S/rd/sentinel"
MOCK_FAIL_RD_UMOUNT=1
if (be7000_firstboot_main -y -r) >/dev/null 2>&1; then
	fail "rootfs_data unmount failure was accepted"
fi
assert_eq "$(cat "$S/rd/sentinel")" rootfs-data-survives "rootfs_data backing changed after failed unmount"
staged_sentinel=
for p in "$S"/tmp/*/rd/sentinel; do
	[ -f "$p" ] || continue
	staged_sentinel="$p"
	break
done
[ -n "$staged_sentinel" ] || fail "mounted rootfs_data was removed after failed unmount"
assert_eq "$(cat "$staged_sentinel")" rootfs-data-survives "mounted rootfs_data contents changed after failed unmount"
[ ! -s "$S/calls" ] || fail "failed rootfs_data unmount rebooted"
assert_eq "$(cat "$S/overlay/upper/etc/config/old")" old-upper "failed unmount changed active upper"
assert_eq "$(cat "$S/overlay/work/work/state")" old-work "failed unmount changed active work"

# Source the preinit implementation without registering a real boot hook.
INITRAMFS=1
. "$ROOT/overlay-files/lib/preinit/78_be7000_factory_reset"
. "$ROOT/overlay-files/lib/preinit/77_be7000_slot_storage"
# The real UUID lookup reads "block info": the match ignores case, needs the
# whole UUID, and is not taken in by a label that happens to hold it.
block() {
	cat <<-'EOT'
		/dev/ubi0_1: UUID="1111aaaa-0000-0000-0000-000000000000" VERSION="4.0" TYPE="squashfs"
		/dev/sda1: UUID="0F3C5D1E-aaaa-bbbb-cccc-1234567890abcd" LABEL="other" TYPE="ext4"
		/dev/sdb1: UUID="0F3C5D1E-aaaa-bbbb-cccc-1234567890ab" LABEL="be7000_overlay" TYPE="ext4"
		/dev/sdc1: LABEL="uuid=0f3c5d1e-aaaa-bbbb-cccc-1234567890ff" PARTUUID="0f3c5d1e-aaaa-bbbb-cccc-1234567890ee" TYPE="vfat"
	EOT
}
assert_eq "$(bfr_by_uuid 0f3c5d1e-AAAA-bbbb-cccc-1234567890ab)" /dev/sdb1 "UUID lookup"
assert_eq "$(bfr_by_uuid 0f3c5d1e-aaaa-bbbb-cccc-1234567890abcd)" /dev/sda1 "UUID lookup of the longer UUID"
assert_eq "$(bfr_by_uuid 0f3c5d1e-aaaa-bbbb-cccc-1234567890ff)" "" "UUID lookup matched a label"
assert_eq "$(bfr_by_uuid 0f3c5d1e-aaaa-bbbb-cccc-1234567890ee)" "" "UUID lookup matched a partition UUID"
assert_eq "$(bfr_by_uuid 0f3c5d1e-aaaa)" "" "UUID lookup matched a part of a UUID"
assert_eq "$BFR_WAIT" 15 "seconds a disk is waited for"
bfr_uuid_valid 0f3c5d1e-aaaa-bbbb-cccc-1234567890ab || fail "ext4 UUID was rejected"
bfr_uuid_valid 1234-ABCD || fail "FAT serial was rejected"
if bfr_uuid_valid '../../etc' || bfr_uuid_valid '' || bfr_uuid_valid 'a b'; then
	fail "a malformed UUID was accepted"
fi

# From here on the disk is what the test says: MOCK_UUID_DEV is the device
# that carries the job's UUID, from poll number MOCK_UUID_FROM on.
bfr_by_uuid() {
	local n
	n=$(cat "$MOCK_UUID_POLLS" 2>/dev/null || echo 0)
	n=$((n + 1))
	echo "$n" > "$MOCK_UUID_POLLS"
	[ -n "${MOCK_UUID_DEV:-}" ] && [ "$n" -ge "${MOCK_UUID_FROM:-1}" ] || return 0
	printf '%s\n' "$MOCK_UUID_DEV"
}
sleep() { MOCK_SLEEPS=$((MOCK_SLEEPS + 1)); }
MOCK_SLEEPS=0
target_mounts() { grep -c -- "/target\$" "$MOCK_MOUNTS" || :; }

bfr_log() { echo "$*" >> "$MOCK_CALLS"; }
bfr_rootfs_data() { printf '%s\n' /dev/ubi0_2; }
bfr_fatal() {
	MOCK_FATAL=1
	echo "fatal:$*" >> "$MOCK_CALLS"
	return 0
}
bfr_write_token() {
	[ "${MOCK_FAIL_CONTROL:-}" != marker_write ] || return 1
	printf '%s\n' "$1" > "$2"
}
s77_vol() {
	case "$1:$2" in
	ubi2:be7000_storage) printf '%s\n' /dev/ubi2_0 ;;
	ubi0:rootfs_data) printf '%s\n' /dev/ubi0_2 ;;
	*) return 1 ;;
	esac
}
s77_log() { echo "$*" >> "$MOCK_CALLS"; }
s77_fatal() {
	MOCK_FATAL=1
	echo "s77-fatal:$*" >> "$MOCK_CALLS"
	return 0
}

# Fault injection is limited to the target rebuild operations. All other cp,
# mv, and rm calls use the host tools unchanged.
cp() {
	local last="" a
	for a in "$@"; do last="$a"; done
	case "${MOCK_FAIL_PREP:-}:$last" in
	copy_fstab:*.be7000_factory_reset_upper.*.new/etc/config/fstab) return 1 ;;
	copy_bigoverlay:*.be7000_factory_reset_upper.*.new/etc/config/bigoverlay) return 1 ;;
	esac
	command cp "$@"
}

mkdir() {
	local last="" a
	for a in "$@"; do last="$a"; done
	case "${MOCK_FAIL_CONTROL:-}:$last" in
	quarantine_mkdir:*/rootfs_data/upper/etc/config) return 1 ;;
	esac
	command mkdir "$@"
}

mv() {
	local src="$1" dst="$2"
	case "${MOCK_FAIL_PREP:-}:$src:$dst" in
	upper_to_old:*/target/upper:*.be7000_factory_reset_upper.*.old) return 1 ;;
	work_to_old:*/target/work:*.be7000_factory_reset_work.*.old) return 1 ;;
	newup_to_upper:*.be7000_factory_reset_upper.*.new:*/target/upper) return 1 ;;
	newwork_to_work:*.be7000_factory_reset_work.*.new:*/target/work) return 1 ;;
	esac
	case "${MOCK_FAIL_CONTROL:-}:$src:$dst" in
	fstab_save:*/upper/etc/config/fstab:*/.be7000_factory_reset/rootfs-fstab.saved) return 1 ;;
	rootfstab_save:*/etc/config/fstab:*/.be7000_factory_reset/rootfs-fstab.root.saved) return 1 ;;
	fstab_marker:*/.be7000_factory_reset/extroot-blocked.new:*/.be7000_factory_reset/extroot-blocked) return 1 ;;
	esac
	command mv "$@"
}

rm() {
	local a done=""
	case "${MOCK_FAIL_CONTROL:-}:$*" in
	fstab_remove:*rootfs_data/upper/etc/config/fstab*) return 1 ;;
	rootfstab_remove:*rootfs_data/etc/config/fstab*) return 1 ;;
	blocked_fstab_remove:*rootfs_data/upper/etc/config/fstab*) return 1 ;;
	blocked_rootfstab_remove:*rootfs_data/etc/config/fstab*) return 1 ;;
	marker_cleanup:*rootfs_data/.be7000_factory_reset/extroot-blocked.new*) return 1 ;;
	esac
	for a in "$@"; do
		case "$a" in */.be7000_factory_reset_done.*) done="$a" ;; esac
	done
	if [ "${MOCK_LEAVE_DONE:-0}" = 1 ] && [ -n "$done" ]; then
		command rm -rf "$done/config" 2>/dev/null
		return 1
	fi
	command rm "$@"
}

TOKEN=0123456789abcdef0123456789abcdef

make_job() {
	local device="$1" fstype="$2" keep="$3" job="$MOCK_RD_BACKING/$BFR_JOB"
	mkdir -p "$job/config"
	printf '%s\n' 1 > "$job/version"
	printf '%s\n' "$device" > "$job/device"
	printf '%s\n' "$fstype" > "$job/fstype"
	printf '%s\n' "$TOKEN" > "$job/token"
	printf '%s\n' "$keep" > "$job/keep"
	printf '%s\n' fstab-kept > "$job/config/fstab"
	printf '%s\n' bigoverlay-kept > "$job/config/bigoverlay"
}

setup_run_case() {
	local name="$1" device="$2" fstype="$3" keep="$4"
	S="$TMP/run-$name"
	MOCK_RD_BACKING="$S/rd"
	MOCK_TARGET_BACKING="$S/target"
	MOCK_RD_MOUNT=
	MOCK_TARGET_MOUNT=
	MOCK_CALLS="$S/calls"
	MOCK_MOUNTS="$S/mount-calls"
	MOCK_FAIL_TARGET_MOUNT=0
	MOCK_FAIL_TARGET_UMOUNT=0
	MOCK_FAIL_RD_UMOUNT=0
	MOCK_FAIL_PREP=
	MOCK_FAIL_CONTROL=
	MOCK_FATAL=0
	MOCK_LEAVE_DONE=0
	MOCK_UUID_DEV=
	MOCK_UUID_FROM=1
	MOCK_UUID_POLLS="$S/uuid-polls"
	MOCK_SLEEPS=0
	BFR_TMP="$S/mounts"
	mkdir -p "$MOCK_RD_BACKING/upper/etc/config" \
		"$MOCK_RD_BACKING/etc/config" \
		"$MOCK_TARGET_BACKING/upper/etc/config" \
		"$MOCK_TARGET_BACKING/work/work" "$MOCK_TARGET_BACKING/stock-etc" \
		"$MOCK_TARGET_BACKING/userdisk"
	printf '%s\n' extroot-active > "$MOCK_RD_BACKING/upper/etc/config/fstab"
	printf '%s\n' legacy-extroot-active > "$MOCK_RD_BACKING/etc/config/fstab"
	printf '%s\n' old-setting > "$MOCK_TARGET_BACKING/upper/etc/config/old"
	printf '%s\n' old-work > "$MOCK_TARGET_BACKING/work/work/state"
	printf '%s\n' stock > "$MOCK_TARGET_BACKING/stock-etc/settings"
	printf '%s\n' userdisk > "$MOCK_TARGET_BACKING/userdisk/file"
	printf '%s\n' migrated > "$MOCK_TARGET_BACKING/.bigoverlay_migrated"
	printf '%s\n' slot-ready > "$MOCK_TARGET_BACKING/.be7000_slotstorage_ready"
	ln -s 2 "$MOCK_TARGET_BACKING/.fs_state"
	printf '%s\n' upgrade > "$MOCK_TARGET_BACKING/sysupgrade.tgz"
	printf '%s\n' "$TOKEN" > "$MOCK_TARGET_BACKING/$BFR_MARK"
	: > "$MOCK_CALLS"
	: > "$MOCK_MOUNTS"
	make_job "$device" "$fstype" "$keep"
}

assert_extroot_blocked() {
	local rd="$1"
	assert_absent "$rd/upper/etc/config/fstab" "pending reset extroot fstab"
	assert_absent "$rd/etc/config/fstab" "pending reset legacy extroot fstab"
	assert_file "$rd/$BFR_JOB/extroot-blocked" "pending reset block marker"
}

assert_extroot_restored() {
	local rd="$1"
	assert_file "$rd/upper/etc/config/fstab" "restored rootfs_data fstab"
	assert_eq "$(cat "$rd/upper/etc/config/fstab")" fstab-kept "restored rootfs_data fstab contents"
	assert_absent "$rd/etc/config/fstab" "legacy rootfs_data fstab remained active"
}

assert_fresh_target() {
	local t="$1"
	assert_file "$t/upper/etc/config/fstab" "fresh fstab"
	assert_file "$t/upper/etc/config/bigoverlay" "fresh bigoverlay"
	assert_eq "$(find "$t/upper" -mindepth 1 -print | wc -l | tr -d '[:space:]')" 4 "fresh upper contents"
	[ -d "$t/work" ] || fail "fresh work is missing"
	assert_eq "$(find "$t/work" -mindepth 1 -print | wc -l | tr -d '[:space:]')" 0 "fresh work contents"
	assert_eq "$(cat "$t/stock-etc/settings")" stock "stock settings changed"
	assert_eq "$(cat "$t/userdisk/file")" userdisk "stock userdisk changed"
	assert_eq "$(cat "$t/.bigoverlay_migrated")" migrated "bigoverlay marker changed"
	assert_eq "$(cat "$t/.be7000_slotstorage_ready")" slot-ready "slot marker changed"
	assert_eq "$(readlink "$t/.fs_state")" 2 "filesystem state changed"
	assert_absent "$t/$BFR_MARK" "target marker cleanup"
}

# Bigoverlay: reset only the MiWRT upper/work, leave every stock/root-level item.
setup_run_case bigoverlay /dev/ubi1_1 ubifs 0
bfr_run
assert_fresh_target "$MOCK_TARGET_BACKING"
assert_extroot_restored "$MOCK_RD_BACKING"
assert_absent "$MOCK_TARGET_BACKING/sysupgrade.tgz" "default sysupgrade cleanup"
assert_absent "$MOCK_RD_BACKING/$BFR_JOB" "completed job cleanup"

# Re-running after completion is a no-op and keeps the verified fresh pair.
bfr_run
assert_fresh_target "$MOCK_TARGET_BACKING"

# Slot storage follows the same offline path and -k keeps sysupgrade.tgz.
setup_run_case slotstorage /dev/ubi2_0 ubifs 1
bfr_run
assert_fresh_target "$MOCK_TARGET_BACKING"
assert_file "$MOCK_TARGET_BACKING/sysupgrade.tgz" "-k sysupgrade preservation"
grep -F -- '-t ubifs -o rw,noatime /dev/ubi2_0' "$MOCK_MOUNTS" >/dev/null ||
	fail "slot-storage target was not mounted by its recorded device"

# A USB device without the matching marker must remain untouched.
setup_run_case usb_mismatch /dev/sda1 ext4 0
printf '%s\n' fedcba9876543210fedcba9876543210 > "$MOCK_TARGET_BACKING/$BFR_MARK"
bfr_run
assert_eq "$(cat "$MOCK_TARGET_BACKING/upper/etc/config/old")" old-setting "token mismatch changed upper"
assert_eq "$(cat "$MOCK_TARGET_BACKING/work/work/state")" old-work "token mismatch changed work"
assert_file "$MOCK_RD_BACKING/$BFR_JOB/token" "token mismatch retry job"
assert_extroot_blocked "$MOCK_RD_BACKING"
assert_file "$MOCK_TARGET_BACKING/sysupgrade.tgz" "token mismatch sysupgrade"
grep -F -- '-t ext4 -o rw,noatime /dev/sda1' "$MOCK_MOUNTS" >/dev/null ||
	fail "USB target was not mounted by its recorded device and filesystem"
assert_eq "$(cat "$MOCK_RD_BACKING/$BFR_JOB/why")" token "reason left for a token mismatch"
assert_eq "$(target_mounts)" 1 "a disk that mounts was mounted more than once"
assert_eq "$MOCK_SLEEPS" 0 "a disk that is there was waited for"

# If the target is unavailable, no target mutation occurs and the job retries.
# A job without a UUID (written by an older image) goes by the name: the disk
# gets its fifteen seconds, one try a second.
setup_run_case mount_failure /dev/sda1 ext4 0
MOCK_FAIL_TARGET_MOUNT=1
bfr_run
assert_eq "$(cat "$MOCK_TARGET_BACKING/upper/etc/config/old")" old-setting "mount failure changed upper"
assert_eq "$(cat "$MOCK_TARGET_BACKING/work/work/state")" old-work "mount failure changed work"
assert_file "$MOCK_RD_BACKING/$BFR_JOB/token" "mount failure retry job"
assert_extroot_blocked "$MOCK_RD_BACKING"
assert_eq "$(target_mounts)" 16 "tries for a disk that does not show up"
assert_eq "$MOCK_SLEEPS" 15 "seconds waited for a disk that does not show up"
assert_eq "$(cat "$MOCK_RD_BACKING/$BFR_JOB/why")" absent "reason left for a disk that does not show up"
assert_absent "$MOCK_RD_BACKING/$BFR_JOB/why.new" "half-written reason"

# A volume on the internal flash is there or it is not: no waiting.
setup_run_case ubi_mount_failure /dev/ubi2_0 ubifs 0
MOCK_FAIL_TARGET_MOUNT=1
bfr_run
assert_file "$MOCK_RD_BACKING/$BFR_JOB/token" "UBI mount failure retry job"
assert_eq "$(target_mounts)" 1 "tries for a UBI volume that does not mount"
assert_eq "$MOCK_SLEEPS" 0 "a UBI volume was waited for"
assert_eq "$(cat "$MOCK_RD_BACKING/$BFR_JOB/why")" mount "reason left for a UBI volume that does not mount"

UUID=0f3c5d1e-aaaa-bbbb-cccc-1234567890ab

# The disk came up under another name than it had when the reset was asked
# for: it is found by its UUID, and the old name is not even tried.
setup_run_case uuid_renamed /dev/sda1 ext4 0
printf '%s\n' "$UUID" > "$MOCK_RD_BACKING/$BFR_JOB/uuid"
MOCK_UUID_DEV=/dev/sdb1
bfr_run
assert_fresh_target "$MOCK_TARGET_BACKING"
assert_extroot_restored "$MOCK_RD_BACKING"
assert_absent "$MOCK_RD_BACKING/$BFR_JOB" "renamed disk completed job"
grep -F -- '-t ext4 -o rw,noatime /dev/sdb1' "$MOCK_MOUNTS" >/dev/null ||
	fail "the disk was not mounted under the name it has on this boot"
grep -F -- '/dev/sda1' "$MOCK_MOUNTS" >/dev/null &&
	fail "the name recorded on an earlier boot was mounted although the job has a UUID"
assert_eq "$MOCK_SLEEPS" 0 "a disk that is there was waited for"

# The disk needs a few seconds: it is polled once a second and used as soon
# as it is there.
setup_run_case uuid_late /dev/sda1 ext4 0
printf '%s\n' "$UUID" > "$MOCK_RD_BACKING/$BFR_JOB/uuid"
MOCK_UUID_DEV=/dev/sda1
MOCK_UUID_FROM=5
bfr_run
assert_fresh_target "$MOCK_TARGET_BACKING"
assert_absent "$MOCK_RD_BACKING/$BFR_JOB" "late disk completed job"
assert_eq "$MOCK_SLEEPS" 4 "seconds waited for a disk that shows up on the fifth look"
assert_eq "$(cat "$MOCK_UUID_POLLS")" 5 "looks for a disk that shows up on the fifth look"

# The disk is not there, or another one sits in the port (it has another
# UUID, so the lookup finds nothing): after fifteen seconds the boot goes on,
# nothing was mounted, the job and its reason stay.
setup_run_case uuid_absent /dev/sda1 ext4 0
printf '%s\n' "$UUID" > "$MOCK_RD_BACKING/$BFR_JOB/uuid"
bfr_run
assert_eq "$(target_mounts)" 0 "a disk with another UUID was mounted"
[ -z "${MOCK_TARGET_MOUNT:-}" ] || fail "a disk with another UUID was mounted"
assert_eq "$(cat "$MOCK_TARGET_BACKING/upper/etc/config/old")" old-setting "missing disk changed upper"
assert_eq "$(cat "$MOCK_TARGET_BACKING/$BFR_MARK")" "$TOKEN" "missing disk changed the target token"
assert_file "$MOCK_RD_BACKING/$BFR_JOB/token" "missing disk retry job"
assert_extroot_blocked "$MOCK_RD_BACKING"
assert_eq "$MOCK_SLEEPS" 15 "seconds waited for a missing disk"
assert_eq "$(cat "$MOCK_UUID_POLLS")" 16 "looks for a missing disk"
assert_eq "$(cat "$MOCK_RD_BACKING/$BFR_JOB/why")" absent "reason left for a missing disk"
# plugged back in, the same job finishes on the next boot
MOCK_RD_MOUNT=
MOCK_TARGET_MOUNT=
MOCK_UUID_DEV=/dev/sdc1
bfr_run
assert_fresh_target "$MOCK_TARGET_BACKING"
assert_extroot_restored "$MOCK_RD_BACKING"
assert_absent "$MOCK_RD_BACKING/$BFR_JOB" "returned disk completed job"

# Found by UUID but it does not mount: said as such, not as "not there".
setup_run_case uuid_mount_failure /dev/sda1 ext4 0
printf '%s\n' "$UUID" > "$MOCK_RD_BACKING/$BFR_JOB/uuid"
MOCK_UUID_DEV=/dev/sda1
MOCK_FAIL_TARGET_MOUNT=1
bfr_run
assert_file "$MOCK_RD_BACKING/$BFR_JOB/token" "unmountable disk retry job"
assert_eq "$(cat "$MOCK_RD_BACKING/$BFR_JOB/why")" mount "reason left for a disk that does not mount"

# Same UUID, but the token is gone (the filesystem was put back from a copy,
# or the file was removed): nothing is cleared.
setup_run_case uuid_no_token /dev/sda1 ext4 0
printf '%s\n' "$UUID" > "$MOCK_RD_BACKING/$BFR_JOB/uuid"
MOCK_UUID_DEV=/dev/sda1
rm -f "$MOCK_TARGET_BACKING/$BFR_MARK"
bfr_run
assert_eq "$(cat "$MOCK_TARGET_BACKING/upper/etc/config/old")" old-setting "missing token changed upper"
assert_eq "$(cat "$MOCK_TARGET_BACKING/work/work/state")" old-work "missing token changed work"
assert_file "$MOCK_RD_BACKING/$BFR_JOB/token" "missing token retry job"
assert_eq "$(cat "$MOCK_RD_BACKING/$BFR_JOB/why")" token "reason left for a missing token"

# A UUID field that is not a UUID is ignored and the job goes by the name;
# a lookup that points at rootfs_data itself is never mounted.
setup_run_case uuid_malformed /dev/sda1 ext4 0
printf '%s\n' '../../etc' > "$MOCK_RD_BACKING/$BFR_JOB/uuid"
MOCK_UUID_DEV=/dev/sdz9
bfr_run
assert_fresh_target "$MOCK_TARGET_BACKING"
grep -F -- '-t ext4 -o rw,noatime /dev/sda1' "$MOCK_MOUNTS" >/dev/null ||
	fail "a job with a malformed UUID did not go by its device name"
assert_absent "$MOCK_UUID_POLLS" "a malformed UUID was looked up"
setup_run_case uuid_is_rootfs_data /dev/sda1 ext4 0
printf '%s\n' "$UUID" > "$MOCK_RD_BACKING/$BFR_JOB/uuid"
MOCK_UUID_DEV=/dev/ubi0_2
bfr_run
assert_eq "$(target_mounts)" 0 "rootfs_data was mounted as the reset target"
assert_file "$MOCK_RD_BACKING/$BFR_JOB/token" "rootfs_data lookup retry job"
assert_eq "$(cat "$MOCK_TARGET_BACKING/upper/etc/config/old")" old-setting "rootfs_data lookup changed upper"

# Integration with the preceding slot-storage hook: a pending reset suppresses
# fstab self-repair, quarantines both lookup paths while ubi2 stays attached,
# and an early quarantine failure in hook 78 cannot reach the partial target.
setup_run_case s77_early_failure /dev/ubi2_0 ubifs 0
mv "$MOCK_TARGET_BACKING/upper" "$MOCK_TARGET_BACKING/.be7000_factory_reset_upper.$TOKEN.old"
case_root="$S"
S="$case_root/s77"
mkdir -p "$S/rd"
s77_ensure_slotstorage_fstab || fail "slot-storage pending reset quarantine failed"
S="$case_root"
assert_absent "$MOCK_RD_BACKING/upper/etc/config/fstab" "slot-storage recreated upper fstab"
assert_absent "$MOCK_RD_BACKING/etc/config/fstab" "slot-storage recreated legacy fstab"
MOCK_RD_MOUNT=
MOCK_TARGET_MOUNT=
MOCK_FAIL_CONTROL=quarantine_sync
bfr_run
MOCK_FAIL_CONTROL=
[ -z "${MOCK_TARGET_MOUNT:-}" ] || fail "early failure mounted the partial slot-storage target"
assert_eq "$MOCK_FATAL" 1 "early failure did not select fatal handling"
assert_file "$MOCK_TARGET_BACKING/.be7000_factory_reset_upper.$TOKEN.old/etc/config/old" \
	"early failure changed the partial slot-storage target"
# Simulate reboot and prove the partially persisted quarantine converges.
copy_tree "$BFR_TMP/rootfs_data" "$MOCK_RD_BACKING"
clear_dir "$BFR_TMP"
MOCK_RD_MOUNT=
MOCK_TARGET_MOUNT=
MOCK_FATAL=0
bfr_run
assert_fresh_target "$MOCK_TARGET_BACKING"
assert_extroot_restored "$MOCK_RD_BACKING"
assert_absent "$MOCK_RD_BACKING/$BFR_JOB" "slot-storage integration completed job"

# Once a job path exists, malformed job data is fail-closed too. Returning to
# mount_root here could otherwise select a target left partial by an old boot.
setup_run_case invalid_job /dev/ubi2_0 ubifs 0
mv "$MOCK_TARGET_BACKING/upper" "$MOCK_TARGET_BACKING/.be7000_factory_reset_upper.$TOKEN.old"
printf '%s\n' invalid > "$MOCK_RD_BACKING/$BFR_JOB/version"
bfr_run
[ -z "${MOCK_TARGET_MOUNT:-}" ] || fail "invalid job mounted a partial target"
assert_eq "$MOCK_FATAL" 1 "invalid job did not select fatal handling"
assert_file "$MOCK_TARGET_BACKING/.be7000_factory_reset_upper.$TOKEN.old/etc/config/old" \
	"invalid job changed the partial target"

# Inject every fstab quarantine operation failure while the target is already
# partial. No such failure may reach the target mount: production forces a
# reboot and cannot return to mount_root. After the simulated reboot, a clean
# retry must converge from every partially persisted quarantine state.
for point in quarantine_mkdir fstab_save rootfstab_save fstab_remove rootfstab_remove marker_cleanup marker_write fstab_marker quarantine_sync blocked_fstab_remove blocked_rootfstab_remove blocked_sync; do
	setup_run_case "control-$point" /dev/ubi1_1 ubifs 0
	mv "$MOCK_TARGET_BACKING/upper" "$MOCK_TARGET_BACKING/.be7000_factory_reset_upper.$TOKEN.old"
	case "$point" in
	fstab_remove)
		cp -a "$MOCK_RD_BACKING/upper/etc/config/fstab" \
			"$MOCK_RD_BACKING/$BFR_JOB/rootfs-fstab.saved"
		;;
	rootfstab_remove)
		cp -a "$MOCK_RD_BACKING/etc/config/fstab" \
			"$MOCK_RD_BACKING/$BFR_JOB/rootfs-fstab.root.saved"
		;;
	marker_cleanup)
		printf '%s\n' stale > "$MOCK_RD_BACKING/$BFR_JOB/extroot-blocked.new"
		;;
	blocked_fstab_remove|blocked_rootfstab_remove|blocked_sync)
		printf '%s\n' "$TOKEN" > "$MOCK_RD_BACKING/$BFR_JOB/extroot-blocked"
		;;
	esac
	MOCK_FAIL_CONTROL="$point"
	bfr_run
	MOCK_FAIL_CONTROL=
	[ -z "${MOCK_TARGET_MOUNT:-}" ] || fail "$point mounted a preexisting partial target"
	assert_eq "$MOCK_FATAL" 1 "$point did not select fatal quarantine handling"
	assert_file "$MOCK_TARGET_BACKING/.be7000_factory_reset_upper.$TOKEN.old/etc/config/old" \
		"$point changed the partial target"
	# The test fatal hook returns so state can be inspected. Simulate the forced
	# reboot by persisting the mounted rootfs_data image and dropping mounts.
	copy_tree "$BFR_TMP/rootfs_data" "$MOCK_RD_BACKING"
	clear_dir "$BFR_TMP"
	MOCK_RD_MOUNT=
	MOCK_TARGET_MOUNT=
	MOCK_FATAL=0
	bfr_run
	assert_fresh_target "$MOCK_TARGET_BACKING"
	assert_extroot_restored "$MOCK_RD_BACKING"
	assert_absent "$MOCK_RD_BACKING/$BFR_JOB" "$point completed job"
done

# Every failure point after reset processing starts must leave extroot blocked.
# A clean retry must then converge and restore the verified configuration.
for point in upper_to_old work_to_old copy_fstab copy_bigoverlay newup_to_upper newwork_to_work; do
	setup_run_case "fault-$point" /dev/ubi1_1 ubifs 0
	MOCK_FAIL_PREP="$point"
	bfr_run
	MOCK_FAIL_PREP=
	assert_file "$MOCK_RD_BACKING/$BFR_JOB/token" "$point retry job"
	assert_extroot_blocked "$MOCK_RD_BACKING"
	bfr_run
	assert_fresh_target "$MOCK_TARGET_BACKING"
	assert_extroot_restored "$MOCK_RD_BACKING"
	assert_absent "$MOCK_RD_BACKING/$BFR_JOB" "$point completed job"
done

# Resume after a power cut between the upper and work renames.
setup_run_case interrupted /dev/ubi1_1 ubifs 0
mv "$MOCK_TARGET_BACKING/upper" "$MOCK_TARGET_BACKING/.be7000_factory_reset_upper.$TOKEN.old"
bfr_run
assert_fresh_target "$MOCK_TARGET_BACKING"
assert_absent "$MOCK_RD_BACKING/$BFR_JOB" "interrupted job cleanup"

# Resume cleanup after the fresh pair was published in an earlier boot.
setup_run_case prepared /dev/ubi1_1 ubifs 0
clear_dir "$MOCK_TARGET_BACKING/upper"
mkdir -p "$MOCK_TARGET_BACKING/upper/etc/config"
cp -a "$MOCK_RD_BACKING/$BFR_JOB/config/fstab" "$MOCK_TARGET_BACKING/upper/etc/config/fstab"
cp -a "$MOCK_RD_BACKING/$BFR_JOB/config/bigoverlay" "$MOCK_TARGET_BACKING/upper/etc/config/bigoverlay"
clear_dir "$MOCK_TARGET_BACKING/work"
mkdir -p "$MOCK_TARGET_BACKING/.be7000_factory_reset_upper.$TOKEN.old/etc" \
	"$MOCK_TARGET_BACKING/.be7000_factory_reset_work.$TOKEN.old/work"
printf '%s\n' secret > "$MOCK_TARGET_BACKING/.be7000_factory_reset_upper.$TOKEN.old/etc/secret"
printf '%s\n' "$TOKEN" > "$MOCK_RD_BACKING/$BFR_JOB/prepared"
bfr_run
assert_fresh_target "$MOCK_TARGET_BACKING"
assert_absent "$MOCK_TARGET_BACKING/.be7000_factory_reset_upper.$TOKEN.old" "prepared old upper cleanup"
assert_absent "$MOCK_TARGET_BACKING/.be7000_factory_reset_work.$TOKEN.old" "prepared old work cleanup"
assert_absent "$MOCK_TARGET_BACKING/sysupgrade.tgz" "prepared sysupgrade cleanup"
assert_absent "$MOCK_RD_BACKING/$BFR_JOB" "prepared job cleanup"

# The repeated prepared cleanup must still honor -k.
setup_run_case prepared_keep /dev/ubi1_1 ubifs 1
clear_dir "$MOCK_TARGET_BACKING/upper"
mkdir -p "$MOCK_TARGET_BACKING/upper/etc/config"
cp -a "$MOCK_RD_BACKING/$BFR_JOB/config/fstab" "$MOCK_TARGET_BACKING/upper/etc/config/fstab"
cp -a "$MOCK_RD_BACKING/$BFR_JOB/config/bigoverlay" "$MOCK_TARGET_BACKING/upper/etc/config/bigoverlay"
clear_dir "$MOCK_TARGET_BACKING/work"
mkdir -p "$MOCK_TARGET_BACKING/.be7000_factory_reset_upper.$TOKEN.old/etc" \
	"$MOCK_TARGET_BACKING/.be7000_factory_reset_work.$TOKEN.old/work"
printf '%s\n' "$TOKEN" > "$MOCK_RD_BACKING/$BFR_JOB/prepared"
bfr_run
assert_fresh_target "$MOCK_TARGET_BACKING"
assert_absent "$MOCK_TARGET_BACKING/.be7000_factory_reset_upper.$TOKEN.old" "prepared -k old upper cleanup"
assert_absent "$MOCK_TARGET_BACKING/.be7000_factory_reset_work.$TOKEN.old" "prepared -k old work cleanup"
assert_file "$MOCK_TARGET_BACKING/sysupgrade.tgz" "prepared -k sysupgrade preservation"
assert_absent "$MOCK_RD_BACKING/$BFR_JOB" "prepared -k job cleanup"

# A power cut during deletion of the atomically renamed done directory leaves
# no pending job, keeps extroot restored, and cannot block a later reset.
setup_run_case partial_done /dev/ubi1_1 ubifs 0
MOCK_LEAVE_DONE=1
bfr_run
MOCK_LEAVE_DONE=0
assert_fresh_target "$MOCK_TARGET_BACKING"
assert_extroot_restored "$MOCK_RD_BACKING"
assert_absent "$MOCK_RD_BACKING/$BFR_JOB" "partial done pending job"
done_dir="$MOCK_RD_BACKING/.be7000_factory_reset_done.$TOKEN"
[ -d "$done_dir" ] || fail "partial completed directory was not retained"

# The hook filename must sort between storage creation and overlay refresh.
order=$(printf '%s\n' 77_be7000_slot_storage 78_be7000_factory_reset 78_be7000_overlay_refresh | sort)
assert_eq "$order" "$(printf '%s\n' 77_be7000_slot_storage 78_be7000_factory_reset 78_be7000_overlay_refresh)" "preinit hook order"

bfr_device_valid /dev/ubi2_0 || fail "slot-storage device was rejected"
bfr_device_valid /dev/disk/by-uuid/1234-abcd || fail "USB UUID path was rejected"
bfr_device_valid ubi1:cfg || fail "named UBIFS device was rejected"
if bfr_device_valid /dev/../../etc; then
	fail "path traversal device was accepted"
fi

if grep -F -- '-quit' "$ROOT/overlay-files/lib/preinit/78_be7000_factory_reset" >/dev/null; then
	fail "factory-reset preinit uses find -quit, which BusyBox may not support"
fi

# Production fatal handling must force reboot and have no returning path if
# reboot itself unexpectedly returns. Tests override this function above.
fatal_body=$(sed -n '/^bfr_fatal() {$/,/^}$/p' \
	"$ROOT/overlay-files/lib/preinit/78_be7000_factory_reset")
printf '%s\n' "$fatal_body" | grep -F 'reboot -f' >/dev/null ||
	fail "fatal quarantine path does not force reboot"
printf '%s\n' "$fatal_body" | grep -F 'while :; do sleep 3600; done' >/dev/null ||
	fail "fatal quarantine path can return after reboot"
if printf '%s\n' "$fatal_body" | grep -F 'return' >/dev/null; then
	fail "fatal quarantine helper contains a returning path"
fi

echo "factory reset tests: OK"
