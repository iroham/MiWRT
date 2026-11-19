# overlay-ac2100

Files only the Xiaomi Redmi Router AC2100 image gets. `scripts/ac2100/assemble-files.sh` copies the MiWRT pieces shared with the BE7000 (the app service, the MiWRT theme, System, Build update, the translations) from `overlay-files` by an explicit list, then this directory on top, and the ImageBuilder puts the result into the image.

Nothing here is read by the BE7000 build, and nothing in `overlay-files` is changed for this router.

Status: testing. The project has installed the image once, from the stock firmware (2.0.23) to MiWRT 2.1.0 on one router, with the steps of [1-install-en.txt](../docs/instruction/ac2100/1-install-en.txt). It booted on the first try and again after a reboot, both radios came up, the MAC addresses matched the Factory partition, and the web interface and the app service answered. With test builds of the source after 2.1.0 the same router has since had internet on its WAN port (IPv4 and IPv6, nothing answering from the WAN side), checked GitHub for updates, installed and removed a package from the feeds, served a Wi-Fi client on each band, and been updated with its settings kept, freshly installed and restored from a backup. The updater's download was run with the check as it is from 2.2.0: the 2.1.0 image arrived and its signature and checksum were verified. Not tested yet: applying the setup assistant's settings from a browser (its pages were walked up to the review, the channel step with a change of country, a scan that fails and a second scan), the install step of the updater, a wired client's speed, and TFTP recovery; no recovery path has been exercised. A router on 2.1.0 is updated by hand, once: its updater refuses the download for lack of memory (see the update text).

| File | Purpose |
|---|---|
| `etc/banner` | the console greeting |
| `etc/uci-defaults/10-miwrt-identity` | writes "MiWRT <version> ..." into the description fields people read, leaving the OpenWrt release in the fields third-party scripts check |
| `etc/uci-defaults/90-miwrt-ac2100-network` | software flow offloading on, at the first start only: after an update the script leaves the setting alone, so offloading switched off in LuCI stays off. Packet steering is left as OpenWrt sets it for this SoC at the first boot: on |
| `etc/sysctl.d/20-miwrt-nlbwmon.conf` | lets nlbwmon have the netlink receive buffer it asks for (524288 bytes; the kernel's limit was 180224) |
| `etc/uci-defaults/91-miwrt-wifi-defaults` | enables the Wi-Fi defaults service after an update |
| `etc/init.d/miwrt-wifi-defaults`, `etc/rc.d/S99miwrt-wifi-defaults` | on a fresh install: both radios on, SSID `MiWRT`, the serial number as the password (letters and digits only: the label prints it with a slash, the password has none), 2.4 GHz on automatic channel choice between 1, 6 and 11, 5 GHz on channel 44 (same 80 MHz block as 36; Apple devices meet on 44 for AirDrop and Continuity and leave the network less often when it is there), country GB, no group-key renewal on 5 GHz |
| `etc/sysupgrade.conf` | what an update keeps besides the defaults |
| `lib/upgrade/keep.d/miwrt-ac2100` | an update also keeps `/etc/modules.d/mt7615-txbf`, the switch for transmit beamforming on 5 GHz |

The release file `/etc/miwrt-release` (version, tag, device, tag prefix, the name of this router's checksum list in a release) is written by the assemble script, not kept here; the workflow adds `/etc/apk/keys/public-key.pem`, the MiWRT signing key, when the secret is available.
