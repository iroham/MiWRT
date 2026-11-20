#!/bin/sh
# /usr/bin/xray of miwrt-xray-xz. The program is kept xz-compressed on flash
# and unpacked into /tmp (memory) the first time it runs after a boot or an
# update; every later run starts the unpacked copy at once. A copy whose
# checksum file does not match the packed one is unpacked again.
packed=/usr/share/miwrt-xray/xray.xz
want=$(cat /usr/share/miwrt-xray/xray.sha256 2>/dev/null)
dir=/tmp/miwrt-xray
bin=$dir/xray

if [ -z "$want" ] || [ ! -x "$bin" ] || [ "$(cat "$dir/xray.sha256" 2>/dev/null)" != "$want" ]; then
	umask 077
	mkdir -p "$dir" || exit 1
	tmp=$dir/xray.$$
	if ! xz -dc "$packed" > "$tmp"; then
		rm -f "$tmp"
		echo "xray: could not unpack $packed into $dir (is /tmp full?)" >&2
		exit 1
	fi
	have=$(sha256sum "$tmp" | cut -d' ' -f1)
	if [ -z "$want" ] || [ "$have" != "$want" ]; then
		rm -f "$tmp"
		echo "xray: $packed does not unpack to the program it was packed from" >&2
		exit 1
	fi
	chmod 755 "$tmp"
	# rename is atomic: another start running at the same moment sees the
	# old copy or the new one, never half of one
	mv -f "$tmp" "$bin" && echo "$want" > "$dir/xray.sha256.$$" && mv -f "$dir/xray.sha256.$$" "$dir/xray.sha256"
fi
exec "$bin" "$@"
