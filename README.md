# OpenWrt with PoE for Cisco Meraki MX65 / MX65W

[![Verify](https://github.com/quenode/mx65w-poe-openwrt/actions/workflows/verify.yml/badge.svg)](https://github.com/quenode/mx65w-poe-openwrt/actions/workflows/verify.yml)
[![License: GPL-2.0](https://img.shields.io/badge/License-GPL--2.0-blue.svg)](LICENSE)

Community OpenWrt firmware for the Cisco Meraki MX65 and MX65W that keeps
**native PoE** working while staying on **current upstream snapshots**, so the
normal package manager (`apk`) keeps working.

Upstream OpenWrt supports the MX65 as a plain router, but it has **no support for
the Broadcom BCM59111 PSE** that drives the two PoE+ ports. This project ports
that driver forward to current kernels and packages it as an installable module.

## Downloading

Prebuilt images are published on the
[releases page](https://github.com/quenode/mx65w-poe-openwrt/releases). Two
profiles are built from the same source tree:

| Profile | Device tree | Use it for |
|---|---|---|
| `meraki_mx65` | MX65 | Normal operation. PoE works. |
| `meraki_mx65w` | MX65W | Diagnostic only — enables PCIe so the radios can be enumerated. |

Both include the PoE driver, the LuCI PoE page (`Network → PoE Ports`), and a web
terminal (`Services → Terminal`). A fresh image also applies the documented
network defaults on first boot, so it comes up on `192.168.88.0/24` without
manual `uci` commands.

Verify every download against the `sha256sums` asset published alongside it. The
release workflow re-checks the published checksums and confirms each initramfs
is a structurally valid FIT image.

Building from source is fully supported and gives you the same result — see
[Building](#building).

## Why this exists

If you install a stock OpenWrt snapshot on an MX65:

- The router works, and LuCI / WireGuard / adblock install normally.
- **PoE is dead.** There is no `kmod-hwmon-bcm59111`, so `/sys/class/poe` never
  appears and the PSE firmware is never loaded.

If you install a third-party PoE snapshot build (for example the
`mx65-6.12-poe` branch), PoE works but the build is pinned to an old snapshot.
As soon as upstream moves on, `apk` refuses to install anything:

```
ERROR: unable to select packages:
    conflicts: libubus20260925-...[libubus=2025.11.03~0d4bcb56-r1]
```

Snapshot packages only match the exact snapshot they were built against.

This project builds **today's** snapshot with PoE included, which resolves both
problems at once.

## What you get

| Feature | Status |
|---|---|
| Native PoE on `lan11` / `lan12` | Working (BCM59111 PSE driver) |
| `apk` package manager | Matches upstream snapshot, so it works |
| LuCI web interface | Included (ucode LuCI) |
| WireGuard | Included |
| Ad blocking | `adblock` + `adblock-fast` |
| Graphs / monitoring | `luci-app-statistics` |
| USB storage | `kmod-usb-storage`, ext4, block-mount |
| Web terminal | `ttyd` |
| Wi-Fi / 802.11 | **Not possible - see [docs/WIFI.md](docs/WIFI.md)** |

### Known limitations

- **Wi-Fi cannot be made to work.** The MX65W's Broadcom BCM43520 radios do not
  even enumerate on the bus, and no in-tree driver covers them. Use an external
  access point. Details and alternatives in [docs/WIFI.md](docs/WIFI.md).
- **PoE is a community driver.** Never merged upstream, no support guarantee.
  If PoE reliability matters, a MikroTik with PoE-out is a better choice - see
  [docs/WIFI.md](docs/WIFI.md#poe-alternative).
- The MX65/MX65W reached end-of-support on **28 May 2026**.

## Documentation

| Document | Contents |
|---|---|
| [docs/INSTALL.md](docs/INSTALL.md) | Full installation, from a blank device |
| [docs/NETWORK.md](docs/NETWORK.md) | LAN/WAN setup, DHCP, firewall, handover |
| [docs/POE.md](docs/POE.md) | How PoE works and how to read port state |
| [docs/WIFI.md](docs/WIFI.md) | Why the MX65W radios cannot be used |
| [docs/MX65W-PROBE.md](docs/MX65W-PROBE.md) | Diagnostic build that enables PCIe to enumerate the radios |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Common faults and their fixes |

## Verified on hardware

The following was confirmed on a physical MX65W running this build
(`r0-7670f36`, kernel 6.18.55):

- PoE PSE detected and bound at I2C `0x21`, 60 W budget, all fault registers
  clear, both ports present
- `apk` resolves against the snapshot feeds and installs packages
- LuCI serves its login page over both LAN and the management subnet
- Adblock returns `NXDOMAIN` for blocked domains and resolves allowed ones
- LAN `192.168.88.0/24` with a working DHCP pool and NAT to WAN
- Survives a clean reboot with all of the above intact

PoE has **not** yet been verified delivering power to a real load. Confirm
before relying on it.

## Hardware

| | |
|---|---|
| SoC | Broadcom BCM58525 (dual-core ARM Cortex-A9) |
| Target | `bcm53xx/generic`, device `meraki_mx65` |
| RAM | 256 MB / 512 MB depending on revision |
| Flash | 1 GB NAND (~983 MiB usable UBI) |
| LAN | `lan3`-`lan12` (10 ports) |
| WAN | `wan1`, `wan2` |
| PoE+ | `lan11`, `lan12` (30 W each, 60 W total budget) |
| Wi-Fi | **MX65W only** - BCM43520, unsupported |
| Serial | J5 header, 115200 8N1, 3.3 V |

### Ethernet layout

```
eth0
 |-- wan1
 |-- wan2
 |-- sw0  -- lan3 lan4 lan5 lan6 lan7
 '-- sw1  -- lan8 lan9 lan10 lan11 lan12
```

Traffic between `lan3`-`lan7` and `lan8`-`lan12` is switched inside the Broadcom
switch and does not pass through the CPU.

## Building

### Requirements

- Linux host, ~8 cores and 8 GB RAM minimum (16 GB recommended)
- ~30 GB free disk
- Standard OpenWrt build dependencies

On Debian/Ubuntu:

```sh
sudo apt install bc bison build-essential clang flex gawk gettext git \
  libncurses-dev libssl-dev python3-setuptools rsync swig unzip \
  zlib1g-dev file zstd libelf-dev ecj fastjar java-propose-classpath
```

Building as root additionally requires:

```sh
export FORCE_UNSAFE_CONFIGURE=1
```

Without it GNU tar refuses to configure and the build fails during host
toolchain setup.

### Build

```sh
./scripts/prepare-source.sh
cp config-meraki_mx65.config openwrt/.config
make -C openwrt defconfig
make -C openwrt -j"$(nproc)"
```

`prepare-source.sh` clones OpenWrt at a **pinned revision** so a fresh build
reproduces the published images rather than whatever upstream is that day. For
v1.0.0 that is `r0-7670f36`. It fetches only that one commit, so the clone is
shallow and quick.

If `openwrt/` already exists at a different revision, the script warns and
carries on rather than silently reusing the wrong tree. Remove `openwrt/` to
re-clone, or opt into tracking upstream:

```sh
MERAKI_OPENWRT_REV=master ./scripts/prepare-source.sh
```

Be aware the BCM59111 driver is ported against specific kernel APIs, so a large
jump in kernel version may need that porting redone.

### Output

```
openwrt/bin/targets/bcm53xx/generic/
|-- openwrt-<version>-bcm53xx-generic-meraki_mx65-initramfs.bin
|-- openwrt-<version>-bcm53xx-generic-meraki_mx65-squashfs-sysupgrade.bin
|-- openwrt-<version>-bcm53xx-generic-meraki_mx65w-initramfs.bin
'-- openwrt-<version>-bcm53xx-generic-meraki_mx65w-squashfs-sysupgrade.bin
```

Both profiles are produced by the same source tree; select which one you want
with `config-meraki_mx65.config` or `config-meraki_mx65w-probe.config`.

Verify downloads with the `sha256sums` file in the same directory.

The initramfs image **must keep the exact filename shown above**, and for USB
booting that name is `openwrt-bcm53xx-generic-meraki_mx65-initramfs.bin`. The
replacement U-Boot matches on that exact string and has no `mx65w` entry, so a
renamed MX65W image will silently not be found. See
[docs/MX65W-PROBE.md](docs/MX65W-PROBE.md).

## Installing

See [docs/INSTALL.md](docs/INSTALL.md). The MX65 ships with a U-Boot that cannot
boot Linux from NAND, so it must be replaced before OpenWrt can start.

### Upgrading from an older snapshot

If you are moving from a third-party PoE build (such as `r31914`) to a current
snapshot, you will hit one non-obvious problem: current OpenWrt uses **ucode**
LuCI instead of the older Lua implementation, and a preserved
`/etc/config/uhttpd` carries a `lua_prefix` setting that breaks it.

After upgrading, if LuCI returns an empty page:

```sh
uci delete uhttpd.main.lua_prefix
uci commit uhttpd
/etc/init.d/uhttpd restart
```

This is explained in full in
[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md#luci-returns-an-empty-page).

## How the PoE support works

The BCM59111 is a PoE PSE (Power Supply Equipment) controller on I2C address
`0x21`. Three pieces are needed:

1. **The driver** - `bcm59111.c`, derived from firmware in the Meraki MX64/MX65
   GPL archive. It uploads the PSE firmware, creates sysfs interfaces, and
   controls each port.
2. **A device-tree node** - declares the chip so the driver can bind, including
   the port count and 60 W power budget.
3. **Package wiring** - `kmod-hwmon-bcm59111`, so it installs and autoloads like
   any other kernel module.

See [docs/POE.md](docs/POE.md) for details, including how to read port state.

## Credits

- **Cisco Meraki** - MX64/MX65 GPL firmware release, original source of the PoE
  driver.
- **Matthew Hagan** - original BCM59111 driver and device-tree work.
- **Matthew Bilker** - `bcm53xx` hwmon packaging.
- **Dimma Don't** - firmware extraction, unload fixes, and the PoE snapshot
  builds this project builds on.
- **clayface** - U-Boot for the MX65, without which the device cannot boot
  OpenWrt.
- **OpenWrt community** - `bcm53xx` target support.

## License

The OpenWrt build system is GPL-2.0. The PoE driver is derived from Cisco's GPL
firmware release and is likewise GPL-2.0. See [LICENSE](LICENSE).