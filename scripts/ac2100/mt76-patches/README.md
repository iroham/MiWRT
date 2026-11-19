# Patches to OpenWrt's mt76 for the Redmi AC2100 image

The Redmi AC2100 image takes every package from the official OpenWrt feeds,
with one exception: the two kernel modules of the 5 GHz driver
(`mt7615-common.ko` and `mt7615e.ko`) are built from OpenWrt's own mt76
source with the patch in this directory. `scripts/ac2100/build-wifi-driver.sh`
builds them with the official OpenWrt SDK, and the image build puts them in
place of the two files the packages bring. The BE7000 build does not read
this directory.

| Patch | What it does | From |
| --- | --- | --- |
| `999-mt7615-experimental-txbf.patch` | explicit transmit beamforming (VHT, single user) for the MT7615, behind the module parameter `txbf`, off by default | Lutfil Hadi, <https://github.com/lutfilhadimohdafez/mt7615-txbf> at commit 1aec8fd (the patch is dated 23 October 2026), unchanged; under mt76's licence (BSD-3-Clause-Clear) |

The patch is written for mt76 at commit 39c960c3 (19 March 2026), the one
OpenWrt 25.12.6 builds. The build script stops when the SDK's mt76 is another
commit: the patch has to be looked at again then, not applied blindly.

With `txbf` off the modules behave as OpenWrt's own: the patch only acts
where the parameter is set, apart from three counters in debugfs. To switch
beamforming on, see "5 GHz download is slower than upload" in
`docs/instruction/ac2100/3-recovery-and-problems-en.txt`.
