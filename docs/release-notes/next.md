# Next release

Notes for the release after 2.1.0. Rename this file to the tag (`v<version>.md`) when the version is chosen: the build takes the release text from `docs/release-notes/<tag>.md`.

## In this release

- **Updates clean up after themselves on every build, not only on a new kernel.** With the settings on the data partition, the joined spare slot or a USB disk, an update between releases that share a kernel (1.5.4.1, 2.0.0 and 2.1.0 do) used to leave old copies of firmware files in front of the new ones, and the package list kept describing the old firmware: old versions, a theme that is gone, a new package missing. The router now remembers the build its settings last ran with and tidies up on the first boot of any other build. Old copies are moved to `.be7000-replaced/` on the settings volume, nothing is deleted, and your settings, added packages and own feeds stay. Feed addresses of an earlier firmware are taken out of the list. This covers settings on a USB disk too: the disk is tidied on the first boot after the update, just before the router restarts onto it, and kernel modules on it that belong to an older kernel are set aside.
- **First-boot scripts of the new firmware run again after an update**, as on any OpenWrt router, so a default that changed in a release reaches routers that keep their settings outside the firmware slot. They leave your settings alone.
- **A theme you chose stays after an update.** The MiWRT theme only takes over on a new install, or when the chosen theme is no longer installed.
- **The app gets its answers faster.** The router compiled the app service's code again for every request from the phone and for every 30-second pass. It now keeps a compiled copy in memory and makes it again when the code or ucode changes. On the Redmi AC2100 a request took 0.6 s and takes 0.2 s, and the passes use a third of the processor time they did. The BE7000 compiled the code in 0.07 s and gains that much per request.
- **Speed shaping works on a new install.** The example queue of sqm-scripts names a port these routers do not have (`eth1`), so switching shaping on in the app or on the SQM page shaped nothing, and the app showed the wrong limits. The example now names the internet port. Only the untouched example is changed: a queue you set up or switched on stays as it is.
- **The LED watcher runs only when it has work**: while an LED uses the "State (MiWRT)" trigger. An LED you move from that trigger to another one now keeps the new trigger; depending on timing it could be switched off a few seconds later.
- Redmi AC2100: **on a new install, 2.4 GHz chooses its channel itself.** At every start the radio measures channels 1, 6 and 11 and takes the quietest, instead of channel 1 everywhere. 5 GHz stays on channel 36. A router that is already set up keeps its channels.
- Redmi AC2100: the traffic counter (nlbwmon) gets the netlink buffer it asks for; the kernel cut it to a third and nlbwmon logged that at every start.

## Good to know

- The first boot of this release on a router updated from 2.1.0 or older does the clean-up once, for everything that collected so far.
- Files you listed in `/etc/sysupgrade.conf` are yours to keep: they are never moved, also when the new firmware ships a newer copy.
- Redmi AC2100: automatic channel choice takes about 7 seconds, so the 2.4 GHz network appears that much later after a restart. For a fixed channel, set one under Network, Wireless.
- Redmi AC2100: the texts said packet steering is off. It is on, as OpenWrt sets it for this processor at the first boot, and was on in 2.1.0; a line that meant to switch it off never took effect and is gone. Nothing changes on a router.
- Redmi AC2100: the image is still in testing. 2.1.0 was installed once from the stock firmware (2.0.23) on one router and ran; the texts in the archive now say what that showed and what is not tested yet, tell you to back up the flash first, explain how to reach the stock firmware's old SSH server, and say that the default Wi-Fi password is the serial number without the slash.
