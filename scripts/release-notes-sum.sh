#!/bin/sh
# Prints the text of a release with the checksum of one archive at its end.
#
# The release of a tag holds the archives of both routers, each put there by
# its own build (build.yml for the BE7000, build-ac2100.yml for the Redmi
# AC2100). The build that finds the release already made adds its line this
# way, and a rerun replaces the line it left before.
#
#   scripts/release-notes-sum.sh ARCHIVE "TEXT OF THE RELEASE SO FAR"
set -eu

ZIP=$1 BODY=${2:-}
[ -s "$ZIP" ] || { echo "no such archive: $ZIP" >&2; exit 1; }
name=$(basename "$ZIP")

# the text without this archive's old line, the hash under it and the empty
# lines above it, and without the empty lines at its end
printf '%s\n' "$BODY" | tr -d '\r' | awk -v l="SHA-256 of $name" '
	$0 == l { skip = 2; blank = 0 }
	skip > 0 { skip--; next }
	/^$/ { blank++; next }
	{ for (; blank > 0; blank--) print ""; print }'
printf '\nSHA-256 of %s\n%s\n' "$name" "$(sha256sum "$ZIP" | cut -d' ' -f1)"
