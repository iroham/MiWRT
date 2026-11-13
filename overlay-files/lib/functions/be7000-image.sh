#!/bin/sh
# Did the image change since these settings last ran?
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
