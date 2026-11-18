#!/bin/sh
# The button "make this slot the main one" on System, Slots (be7000-slots
# switch): what it writes to the bootloader, and when it refuses.
#
# The flash, the bootloader environment and the look into the other slot are
# stand-ins; nothing here touches a router.

set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/be7000-slot-switch.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

fail() { echo "FAIL: $*" >&2; exit 1; }

sed -e '/be7000-factory-reset-guard\.sh/d' -e '/be7000-fstab\.sh/d' -e '/^case "\$1" in$/,$d' \
	"$ROOT/overlay-files/usr/libexec/be7000-slots" > "$TMP/slot-functions"
. "$TMP/slot-functions"

CALLS="$TMP/calls"
ENVDIR="$TMP/env"

# the bootloader environment: one file per variable
fw_setenv() {
	echo "fw_setenv:$*" >> "$CALLS"
	[ "${ENV_READONLY:-0}" = 1 ] && return 0
	[ "${ENV_FAILS:-0}" = 1 ] && return 1
	if [ $# -ge 2 ]; then printf '%s\n' "$2" > "$ENVDIR/$1"; else rm -f "$ENVDIR/$1"; fi
}
env() { cat "$ENVDIR/$1" 2>/dev/null || true; }
logger() { echo "logger:$*" >> "$CALLS"; }
current() { printf '%s\n' "$CURRENT"; }
be7000_factory_reset_pending() { [ "${PENDING:-0}" = 1 ]; }
clear_look() { echo clear_look >> "$CALLS"; LOOKS_BUSY=0; }
stock_settings_flag() { echo stock_settings_flag >> "$CALLS"; }
# what the look into the other slot answers; busy for the first LOOKS_BUSY looks
cmd_info() {
	echo "info:$1" >> "$CALLS"
	if [ "${LOOKS_BUSY:-0}" -gt 0 ]; then
		echo '{"error":"slot already attached"}'
		return 1
	fi
	printf '%s\n' "$INFO"
}

world() {
	rm -rf "$ENVDIR"
	mkdir -p "$ENVDIR"
	printf '%s\n' 1 > "$ENVDIR/flag_last_success"
	printf '%s\n' 1 > "$ENVDIR/flag_boot_rootfs"
	printf '%s\n' 3 > "$ENVDIR/flag_try_sys1_failed"
	printf '%s\n' 2 > "$ENVDIR/flag_try_sys2_failed"
	printf '%s\n' 1 > "$ENVDIR/flag_ota_reboot"
	: > "$CALLS"
	CURRENT=1
	PENDING=0
	LOOKS_BUSY=0
	ENV_READONLY=0
	ENV_FAILS=0
	INFO='{"slot":0,"kind":"openwrt","version":"MiWRT 2.1.0","detached":true}'
}

run() {
	rc=0
	cmd_switch "$@" > "$TMP/out" 2>&1 || rc=$?
}

switched_to() {
	[ "$(env flag_last_success)" = "$1" ] || fail "$2: flag_last_success is $(env flag_last_success)"
	[ "$(env flag_boot_rootfs)" = "$1" ] || fail "$2: flag_boot_rootfs is $(env flag_boot_rootfs)"
	[ "$(env flag_try_sys1_failed)" = 0 ] && [ "$(env flag_try_sys2_failed)" = 0 ] || fail "$2: the failure counters were not cleared"
	[ "$(env flag_ota_reboot)" = 0 ] || fail "$2: a one-time try of the other slot is still set"
	[ "$(env flag_boot_success)" = 1 ] || fail "$2: flag_boot_success is not set"
}

untouched() {
	grep -q '^fw_setenv:' "$CALLS" && fail "$1: the bootloader environment was written"
	[ "$(env flag_last_success)" = 1 ] || fail "$1: flag_last_success changed"
}

# another MiWRT in the other slot
world
run 0
[ "$rc" = 0 ] || fail "switch to an OpenWrt slot failed: $(cat "$TMP/out")"
switched_to 0 "OpenWrt slot"
grep -q '^stock_settings_flag$' "$CALLS" && fail "the stock settings flag was touched for an OpenWrt slot"
grep -q 'slot 0 (openwrt) boots from now on' "$TMP/out" || fail "switch did not say what it did: $(cat "$TMP/out")"

# the factory firmware in the other slot
world
INFO='{"slot":0,"kind":"stock","version":"1.1.37","detached":true}'
run 0
[ "$rc" = 0 ] || fail "switch to the stock slot failed: $(cat "$TMP/out")"
switched_to 0 "stock slot"
grep -q '^stock_settings_flag$' "$CALLS" || fail "the stock settings were not looked at before going to stock"

# The page looked into the slot a moment ago and it is still attached: the
# button used to answer "slot already attached". Clear the look, look again.
world
LOOKS_BUSY=1
run 0
[ "$rc" = 0 ] || fail "switch right after a look failed: $(cat "$TMP/out")"
grep -q '^clear_look$' "$CALLS" || fail "a look that was left behind was not cleared"
[ "$(grep -c '^info:0$' "$CALLS")" = 2 ] || fail "the slot was not looked at again after clearing"
switched_to 0 "switch right after a look"

# nothing to boot there
for INFO_CASE in '{"slot":0,"kind":"empty"}' '{"slot":0,"kind":"storage"}' '{"slot":0,"kind":"unknown","version":"","detached":true}' '{"error":"no such mtd"}' ''; do
	world
	INFO="$INFO_CASE"
	run 0
	[ "$rc" != 0 ] || fail "switch went ahead for: $INFO_CASE"
	untouched "nothing to boot ($INFO_CASE)"
	grep -q 'holds no firmware this can boot (' "$TMP/out" || fail "no reason given for: $INFO_CASE"
	grep -q '()' "$TMP/out" && fail "an empty reason was printed for: $INFO_CASE"
done

# the running slot, a slot that does not exist
world
run 1
[ "$rc" != 0 ] || fail "switch to the running slot went ahead"
untouched "running slot"
for bad in 2 -1 "" x; do
	world
	run "$bad"
	[ "$rc" != 0 ] || fail "switch to slot '$bad' went ahead"
	untouched "slot '$bad'"
done

# a factory reset waits for its disk
world
PENDING=1
run 0
[ "$rc" != 0 ] || fail "switch went ahead while a factory reset waits"
untouched "factory reset pending"
grep -q '^info:' "$CALLS" && fail "the other slot was looked into while a factory reset waits"
grep -q 'factory reset is pending' "$TMP/out" || fail "switch did not say why it refused"

# the bootloader environment cannot be written
world
ENV_FAILS=1
run 0
[ "$rc" != 0 ] || fail "switch was reported as done although the environment cannot be written"

# it takes the write and does not keep it
world
ENV_READONLY=1
run 0
[ "$rc" != 0 ] || fail "switch was reported as done although the environment did not change"
grep -q 'did not take the change' "$TMP/out" || fail "switch did not say that the environment did not change"

echo "slot switch tests: OK"
