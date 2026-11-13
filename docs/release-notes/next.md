# Next release

Notes for the release after 2.1.0. Rename this file to the tag (`v<version>.md`) when the version is chosen: the build takes the release text from `docs/release-notes/<tag>.md`.

## In this release

- **Updates clean up after themselves on every build, not only on a new kernel.** With the settings on the data partition, the joined spare slot or a USB disk, an update between releases that share a kernel (1.5.4.1, 2.0.0 and 2.1.0 do) used to leave old copies of firmware files in front of the new ones, and the package list kept describing the old firmware: old versions, a theme that is gone, a new package missing. The router now remembers the build its settings last ran with and tidies up on the first boot of any other build. Old copies are moved to `.be7000-replaced/` on the settings volume, nothing is deleted, and your settings, added packages and own feeds stay. Feed addresses of an earlier firmware are taken out of the list. This covers settings on a USB disk too: the disk is tidied on the first boot after the update, just before the router restarts onto it, and kernel modules on it that belong to an older kernel are set aside.
- **First-boot scripts of the new firmware run again after an update**, as on any OpenWrt router, so a default that changed in a release reaches routers that keep their settings outside the firmware slot. They leave your settings alone.
- **A theme you chose stays after an update.** The MiWRT theme only takes over on a new install, or when the chosen theme is no longer installed.

## Good to know

- The first boot of this release on a router updated from 2.1.0 or older does the clean-up once, for everything that collected so far.
- Files you listed in `/etc/sysupgrade.conf` are yours to keep: they are never moved, also when the new firmware ships a newer copy.
