#!/bin/sh
# Did the image change since these settings last ran, and what to do to a
# settings volume when it did (second half of this file).
#
# A settings volume that outlives sysupgrade (the data partition, the joined
# spare slot, a USB disk) has to be told when a new image starts on top of it:
# 78_be7000_overlay_refresh then moves old copies of image files out of the
# way and be7000-romsync puts apk's database back in line with the image.
#
# The kernel hash in apk's database is not enough for that. Releases share a
# kernel for a long time (1.5.4.1, 2.0.0 and 2.1.0 have the same one), and an
# update between them changed nothing the old test could see. So the settings
# remember the image they last ran with, in a one-line file of their own:
#
#   /etc/.be7000_image   "BUILD=<run id> VERSION=<version>" from the ROM's
#                        /etc/miwrt-release; the kernel string of the ROM's
#                        apk database for an image built by hand, which has
#                        no release file
#
# It lives among the settings, not beside them at the root of the volume, so
# it goes wherever they go: joining or releasing the spare slot copies upper/
# and nothing else, and a factory reset drops it with the rest. No keep list names it, so the storage inside the firmware slot
# loses it at every sysupgrade, with everything else.
#
# be7000-romsync writes it once the settings are mounted and apk's database
# matches the image. The preinit hook only reads it.
#
# Both callers pass the root of the image ("" in preinit, /rom afterwards),
# the file as they see it and the overlay's copy of apk's database, so they
# cannot disagree about the answer.

# relative to the top of the overlay
BE7000_IMAGE_MARK=etc/.be7000_image

# $1 an apk "installed" database
be7000_image_kernel() {
	grep -oE 'kernel=[0-9.]+~[0-9a-f]{32}' "$1" 2>/dev/null | head -1
}

# $1 root of the image
be7000_image_id() {
	local rom="$1" b v
	b=$(sed -n 's/^BUILD=//p' "$rom/etc/miwrt-release" 2>/dev/null | head -1)
	if [ -n "$b" ]; then
		v=$(sed -n 's/^VERSION=//p' "$rom/etc/miwrt-release" 2>/dev/null | head -1)
		echo "BUILD=$b VERSION=$v"
		return 0
	fi
	be7000_image_kernel "$rom/lib/apk/db/installed"
}

# $1 the note: the image these settings last ran with, empty if there is none
be7000_image_seen() {
	[ -f "$1" ] || return 0
	head -1 "$1" 2>/dev/null
}

# $1 root of the image, $2 the note, $3 the overlay's copy of apk's
# "installed" database. True when the settings last ran with another image.
be7000_image_changed() {
	local rom="$1" mark="$2" ov_db="$3" id rom_k ov_k
	local rom_db="$rom/lib/apk/db/installed"
	id=$(be7000_image_id "$rom")
	[ -n "$id" ] || return 1
	if [ -f "$mark" ]; then
		[ "$(be7000_image_seen "$mark")" = "$id" ] || return 0
	elif [ -f "$ov_db" ] && [ -f "$rom_db" ] && ! cmp -s "$rom_db" "$ov_db"; then
		# No note yet: these settings last ran with an image older than the
		# note itself, or they are new. Only an overlay that carries its own
		# copy of apk's database, and one that does not describe this image,
		# has something to clean. A fresh install has no copy and does nothing.
		return 0
	fi
	# An older image in between does not keep the note up to date; a kernel
	# it left in the database still gives the change away, as it always did.
	rom_k=$(be7000_image_kernel "$rom_db")
	ov_k=$(be7000_image_kernel "$ov_db")
	[ -n "$rom_k" ] && [ -n "$ov_k" ] && [ "$rom_k" != "$ov_k" ]
}

# $1 root of the image, $2 the note: write down that the settings ran with
# this image. Written through a second file so that a power cut leaves either
# the old note or the new one. Fails quietly where nothing can be written.
be7000_image_note() {
	local id mark="$2"
	id=$(be7000_image_id "$1")
	[ -n "$id" ] || return 1
	[ "$(be7000_image_seen "$mark")" = "$id" ] && return 0
	{ echo "$id" > "$mark.new"; } 2>/dev/null && mv "$mark.new" "$mark"
}

# ---------------------------------------------------------------------------
# Cleaning a settings volume for a new image
#
# Over time the overlay collects copies of files that belong to the image
# itself: rc.d links, init scripts, /etc/os-release, /etc/modules.d entries,
# whole packages reinstalled by apk. After an upgrade those old copies shadow
# the new image. An old /etc/modules.d/ath12k without the ath12k_wifi7 module,
# for example, hides the 5 GHz radio completely.
#
# Plain OpenWrt never meets this, because sysupgrade keeps only the
# configuration. So this does the same thing once per image change: every
# file in upper/ that also exists in the image is moved away, unless it is a
# conffile of a package, listed in /etc/sysupgrade.conf or /lib/upgrade/keep.d,
# or one of the always kept places below. Nothing is deleted: the moved files
# go to .be7000-replaced/ at the root of the volume, replacing the previous
# batch. The image's first-boot scripts run again, as they do after a
# sysupgrade. Whiteouts of anything else (files the user deleted) stay.
#
# This works on a volume that is mounted on its own, never on the upper of a
# live overlay. 78_be7000_overlay_refresh does it for the built-in volumes
# before mount_root; be7000-extroot does it for a USB disk on the boot before
# the router reboots onto it.
#
# .be7000-replaced/.image names the image a batch was made for. The first boot
# after an update can run on the slot's own overlay and reboot, or stop before
# be7000-romsync notes the new image in the settings; the next boot then finds
# the same change again, and must not replace the batch with what little is
# left to move. be7000-romsync removes the file when it is done.
# ---------------------------------------------------------------------------

# the image as the caller sees it: "" in preinit, /rom afterwards
: "${BE7000_IMAGE_ROOT:=}"
: "${BE7000_KEEP:=/tmp/be7000-refresh.keep}"
: "${BE7000_FILES:=/tmp/be7000-refresh.files}"

be7000_refresh_log() {
	{ echo "- be7000: $* -" > /dev/kmsg; } 2>/dev/null || :
}

# a file the overlay left in upper/ to say "deleted": a character device 0,0
be7000_is_whiteout() {
	[ -c "$1" ]
}

be7000_keep_list() {
	local up="$1"
	# one cat for all of them: lists that do not exist are simply skipped
	cat "$BE7000_IMAGE_ROOT"/lib/apk/packages/*.conffiles "$up"/lib/apk/packages/*.conffiles \
		"$BE7000_IMAGE_ROOT/etc/sysupgrade.conf" "$up/etc/sysupgrade.conf" \
		"$BE7000_IMAGE_ROOT"/lib/upgrade/keep.d/* "$up"/lib/upgrade/keep.d/* 2>/dev/null |
		sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e '/^$/d' -e 's|^/||' -e 's|/$||' | sort -u > "$BE7000_KEEP"
}

# $1 relative path; kept when listed itself or below a listed directory
be7000_is_kept() {
	local p="$1"
	while [ -n "$p" ] && [ "$p" != "." ]; do
		grep -qxF "$p" "$BE7000_KEEP" && return 0
		p=$(dirname "$p")
	done
	return 1
}

# $1 path relative to upper/: true when the image has its own copy and the
# overlay one is not configuration the user keeps across upgrades
be7000_replaced_by_image() {
	case "$1" in
	etc/config/*|etc/apk/*|lib/apk/*|lib/modules/*|lib/modules.stale-*|root/*|\
	etc/dropbear/*|etc/uhttpd.crt|etc/uhttpd.key|etc/shadow|etc/passwd|etc/group|\
	etc/luci-uploads/*|etc/sysupgrade.conf|etc/rc.local|etc/crontabs/*|etc/be7000-reinstall)
		return 1 ;;
	esac
	[ -e "$BE7000_IMAGE_ROOT/$1" ] || [ -L "$BE7000_IMAGE_ROOT/$1" ] || return 1
	be7000_is_kept "$1" && return 1
	return 0
}

# $1 upper dir, $2 where the moved files go. The previous batch is replaced
# only when there is something to put in its place.
be7000_refresh_upper() {
	local up="$1" stash="$2" f n=0
	[ -d "$up" ] || return 0
	be7000_keep_list "$up"
	(cd "$up" && find . \( -type f -o -type l \)) | sed 's|^\./||' > "$BE7000_FILES"
	while read -r f; do
		be7000_replaced_by_image "$f" || continue
		[ "$n" = 0 ] && rm -rf "$stash"
		mkdir -p "$stash/$(dirname "$f")"
		mv "$up/$f" "$stash/$f" && n=$((n + 1))
	done < "$BE7000_FILES"
	rm -f "$BE7000_FILES" "$BE7000_KEEP"
	be7000_refresh_log "moved $n copies of image files out of $up"
}

# $1 upper dir. A first-boot script (/etc/uci-defaults) deletes itself when
# it is done, which the overlay records as a whiteout, and that whiteout hides
# the script of the same name in every later image. After a sysupgrade on
# plain storage all of them run again; they are written to leave existing
# settings alone. Taking their whiteouts away gives the same here. A whiteout
# holds nothing, so it is removed, not moved.
be7000_refresh_firstboot() {
	local up="$1" f name names=""
	for f in "$up"/etc/uci-defaults/*; do
		be7000_is_whiteout "$f" || continue
		name=${f##*/}
		[ -e "$BE7000_IMAGE_ROOT/etc/uci-defaults/$name" ] || continue
		rm -f "$f" && names="$names $name"
	done
	[ -z "$names" ] || be7000_refresh_log "first-boot scripts of the image that run again:$names"
}

# $1 root of a mounted settings volume
be7000_refresh_volume() {
	local vol="$1" stash="$1/.be7000-replaced" id seen
	local mark="$1/upper/$BE7000_IMAGE_MARK"
	be7000_image_changed "$BE7000_IMAGE_ROOT" "$mark" "$vol/upper/lib/apk/db/installed" || return 0
	id=$(be7000_image_id "$BE7000_IMAGE_ROOT")
	[ "$(cat "$stash/.image" 2>/dev/null)" = "$id" ] && return 0
	seen=$(be7000_image_seen "$mark")
	be7000_refresh_log "the image is $id, the settings on this volume last ran with ${seen:-an older one}"
	be7000_refresh_upper "$vol/upper" "$stash"
	be7000_refresh_firstboot "$vol/upper"
	mkdir -p "$stash" && echo "$id" > "$stash/.image"
	sync
}

# $1 root of a mounted settings volume. Kernel modules in it that were built
# for another kernel than the image's are set aside, exactly as
# 79_be7000_stale_modules does at preinit for the built-in volumes. That hook
# stands on its own; this is for a volume it cannot reach, a USB disk.
be7000_stale_modules_volume() {
	local vol="$1" dir rom_k ov_k stale
	dir="$vol/upper/lib/modules/$(uname -r)"
	[ -d "$dir" ] || return 0
	rom_k=$(be7000_image_kernel "$BE7000_IMAGE_ROOT/lib/apk/db/installed")
	ov_k=$(be7000_image_kernel "$vol/upper/lib/apk/db/installed")
	[ -n "$rom_k" ] && [ -n "$ov_k" ] && [ "$rom_k" != "$ov_k" ] || return 0
	be7000_refresh_log "modules on this volume were built for kernel ${ov_k##*~}, the image has ${rom_k##*~}; setting them aside"
	rm -rf "$vol"/upper/lib/modules.stale-*
	stale="$vol/upper/lib/modules.stale-${ov_k##*~}"
	mkdir -p "$stale" && mv "$dir" "$stale/"
	rmdir "$vol/upper/lib/modules" 2>/dev/null || :
	sync
}
