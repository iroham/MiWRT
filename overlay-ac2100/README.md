# overlay-ac2100

Files only the Xiaomi Redmi Router AC2100 image gets. `scripts/ac2100/assemble-files.sh` copies the MiWRT pieces shared with the BE7000 (the app service, the MiWRT theme, System, Build update, the translations) from `overlay-files` by an explicit list, then this directory on top, and the ImageBuilder puts the result into the image.

Nothing here is read by the BE7000 build, and nothing in `overlay-files` is changed for this router.

Status: testing. The project has installed the image once, from the stock firmware (2.0.23) to MiWRT 2.1.0 on one router, with the steps of [1-install-en.txt](../docs/instruction/ac2100/1-install-en.txt). It booted on the first try and again after a reboot, both radios came up, the MAC addresses matched the Factory partition, and the web interface and the app service answered. Not tested yet: internet on the WAN port, the updater and the package feeds, a Wi-Fi client, the setup assistant in a browser, sysupgrade to a later version, and TFTP recovery; no recovery path has been exercised.

| File | Purpose |
|---|---|
| `etc/banner` | the console greeting |
| `etc/uci-defaults/10-miwrt-identity` | writes "MiWRT <version> ..." into the description fields people read, leaving the OpenWrt release in the fields third-party scripts check |
| `etc/uci-defaults/90-miwrt-ac2100-network` | software flow offloading on, packet steering explicitly off |
| `etc/uci-defaults/91-miwrt-wifi-defaults` | enables the Wi-Fi defaults service after an update |
| `etc/init.d/miwrt-wifi-defaults`, `etc/rc.d/S99miwrt-wifi-defaults` | on a fresh install: both radios on, SSID `MiWRT`, the serial number as the password (letters and digits only: the label prints it with a slash, the password has none), country GB, no group-key renewal on 5 GHz |
| `etc/sysupgrade.conf` | what an update keeps besides the defaults |

The release file `/etc/miwrt-release` (version, tag, device, tag prefix, the name of this router's checksum list in a release) is written by the assemble script, not kept here; the workflow adds `/etc/apk/keys/public-key.pem`, the MiWRT signing key, when the secret is available.
