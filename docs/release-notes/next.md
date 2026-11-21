# After 2.3.0

Notes for the release after 2.3.0 collect here. Before the tag the file is renamed to `v<version>.md`; the build takes the release text from `docs/release-notes/<tag>.md`.

## Fixed

- Redmi AC2100: **a router that comes from another OpenWrt with its settings keeps its Wi-Fi exactly as it was.** The first start used to set the country to GB on radios that had none, which changes the channels and transmit power allowed, and it turned on its own "MiWRT" networks when the old firmware had Wi-Fi switched off or open. Now a router with a root password, a Wi-Fi network with a password or one switched on counts as set up, and its Wi-Fi and its choice of software flow offloading are left alone. A router with none of these is treated as new, as before.
- Redmi AC2100: **what an update keeps no longer depends on `/etc/sysupgrade.conf`.** The two MiWRT lines there (which services are on, and the note that the first start is done) moved to `/lib/upgrade/keep.d/miwrt-ac2100`, which is part of the image. A router that came from another OpenWrt with its own edited `sysupgrade.conf` kept that file, and its next update then lost both.
- Both fixes were tried on a Redmi AC2100: from official OpenWrt 25.12.6 with the settings kept, and through the next update after that.
