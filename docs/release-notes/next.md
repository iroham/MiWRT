# After 2.2.0

Notes for the release after 2.2.0 collect here. Before the tag the file is renamed to `v<version>.md`; the build takes the release text from `docs/release-notes/<tag>.md`.

## In this release

- BE7000: **the build checks the firmware image against the size of its slot.** The slot is 40 MiB of flash: 296 blocks of 124 KiB for the kernel, the system and the in-slot settings volume. The limit written in the image recipe was never compared with anything, so an image that outgrew the slot would have been noticed by the router, while it writes the update. Now the build refuses an image that would leave the in-slot settings volume less than 25 blocks (3 MiB). With the settings on the data partition (the default) that volume only holds the pointer to them; it is the whole settings space of a router that keeps `bigoverlay` off.
- BE7000: **the system is compressed in 1 MiB blocks** instead of 256 KiB, which makes the image about half a megabyte smaller.
- BE7000: **`tcpdump-mini` and `iperf3` are no longer in the image**, and `ethtool-full` gave way to the plain `ethtool`. `apk add tcpdump-mini iperf3` brings the first two back; the feed has `tcpdump` and `ethtool-full` as well.
