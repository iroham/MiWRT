#!/bin/sh
# fstab helpers for the scripts that decide where /overlay lives
# (be7000-extroot, be7000-slots, bigoverlay).
#
# "uci batch" answers success even when it wrote nothing. With no config file
# every command in the batch fails quietly, a command that names a section
# that is not there fails quietly, and so does a commit on a full volume. A
# storage change that went by that answer said "done" and left the router
# where it was after the reboot. So the file is made first, and what matters
# is read back from the file afterwards.

# Make sure <dir>/fstab exists and has its global section.
# $1 config directory
be7000_fstab_ensure() {
	local dir="$1" made=0
	[ -n "$dir" ] || return 1
	mkdir -p "$dir" 2>/dev/null || return 1
	if [ ! -f "$dir/fstab" ]; then
		# a dangling link or a directory under that name is not ours to replace
		[ ! -e "$dir/fstab" ] && [ ! -L "$dir/fstab" ] || return 1
		: > "$dir/fstab" || return 1
		made=1
	fi
	if [ -z "$(be7000_fstab_get "$dir" '@global[0]')" ]; then
		# the values "block detect" writes on a first boot
		uci -q -c "$dir" batch >/dev/null 2>&1 <<-EOT
			add fstab global
			set fstab.@global[-1].anon_swap='0'
			set fstab.@global[-1].anon_mount='0'
			set fstab.@global[-1].auto_swap='1'
			set fstab.@global[-1].auto_mount='1'
			set fstab.@global[-1].delay_root='5'
			set fstab.@global[-1].check_fs='0'
			commit fstab
		EOT
	fi
	[ -n "$(be7000_fstab_get "$dir" '@global[0]')" ] && return 0
	# an empty file made here and not filled does not stay behind
	if [ $made = 1 ] && [ ! -s "$dir/fstab" ]; then
		rm -f "$dir/fstab"
	fi
	return 1
}

# Print one value as the file <dir>/<config> holds it. Changes that were set
# but never reached the file (uci keeps those in /tmp/.uci, also after a
# commit that failed) do not count: the file is read from a copy under
# another name, for which no such changes exist.
# $1 config directory, $2 config file, $3 section or section.option
be7000_config_get() {
	local dir="$1" cfg="$2" key="$3" tmp out
	[ -f "$dir/$cfg" ] || return 1
	tmp="${BE7000_RESET_TMP:-/tmp}/be7000-config-read.$$"
	mkdir -p "$tmp" || return 1
	cp "$dir/$cfg" "$tmp/be7000_config_copy" || { rmdir "$tmp" 2>/dev/null; return 1; }
	out="$(uci -q -c "$tmp" get "be7000_config_copy.$key" 2>/dev/null)" || out=
	rm -f "$tmp/be7000_config_copy"
	rmdir "$tmp" 2>/dev/null
	[ -n "$out" ] || return 1
	printf '%s\n' "$out"
}

# $1 config directory, $2 section or section.option
be7000_fstab_get() {
	be7000_config_get "$1" fstab "$2"
}

# The file has section <2> with every "option value" pair that follows.
# $1 config directory, $2 section, then pairs
be7000_fstab_has() {
	local dir="$1" sec="$2"
	shift 2
	[ -n "$(be7000_fstab_get "$dir" "$sec")" ] || return 1
	while [ $# -ge 2 ]; do
		[ "$(be7000_fstab_get "$dir" "$sec.$1")" = "$2" ] || return 1
		shift 2
	done
	return 0
}

# The file has no section <2>. A file that cannot be read does not count as
# "no such section".
be7000_fstab_lacks() {
	[ -f "$1/fstab" ] || return 1
	[ -z "$(be7000_fstab_get "$1" "$2")" ]
}

# Run "uci batch" (stdin) on <dir>/fstab, which is made first when it is
# missing, then call the check: "$2 <dir> ...". When the check does not hold,
# the file is put back as it was and the answer is failure.
# $1 config directory, $2 check function ("" for none), then its arguments
be7000_fstab_batch() {
	local dir="$1" check="${2:-}" keep rc=0
	shift
	[ $# -eq 0 ] || shift
	be7000_fstab_ensure "$dir" || { echo "cannot create $dir/fstab" >&2; return 1; }
	keep="${BE7000_RESET_TMP:-/tmp}/be7000-fstab-before.$$"
	cp "$dir/fstab" "$keep" || return 1
	uci -q -c "$dir" batch >/dev/null || rc=1
	if [ $rc = 0 ] && [ -n "$check" ]; then
		"$check" "$dir" "$@" || rc=1
	fi
	if [ $rc != 0 ]; then
		# nothing half-made stays behind, in the file or waiting in /tmp/.uci
		uci -q -c "$dir" revert fstab 2>/dev/null || true
		cat "$keep" > "$dir/fstab" 2>/dev/null || true
		echo "the change to $dir/fstab did not reach the file" >&2
	fi
	rm -f "$keep"
	sync
	return $rc
}
