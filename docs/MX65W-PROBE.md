# MX65W PCIe / Wi-Fi probe

## What this is

A diagnostic firmware for the **MX65W** that enables the two Broadcom iPROC
PCIe controllers so the on-board wireless radios can be enumerated.

It is **not** a Wi-Fi capable firmware. No driver binds to BCM43520 and the
required Broadcom firmware was never published. This exists to answer one
question empirically: **are the radios present on this unit, and what PCI device
ID do they report?**

Read [WIFI.md](WIFI.md) first for the full reasoning.

## Why a separate profile is needed

Upstream ships two device trees:

| DTS | PCIe controllers |
|---|---|
| `bcm958625-meraki-mx65.dts` | `status = "disabled"` |
| `bcm958625-meraki-mx65w.dts` | `status = "okay"` |

That two-line difference is the entire difference between the variants:

```
&pcie0 { status = "okay"; };
&pcie1 { status = "okay"; };
```

OpenWrt builds only the `meraki_mx65` profile, so on an MX65W the bus is
disabled and `lspci` shows nothing. Decompiled from the built DTBs:

```
mx65  : status="okay" x7   status="disabled" x14
mx65w : status="okay" x9   status="disabled" x12
```

Two fewer disabled nodes - the two PCIe controllers.

## Images

```
openwrt-bcm53xx-generic-meraki_mx65w-initramfs.bin
  sha256 50d215c7f6e3e8a583ea6104eb1f527354aa7f69021570aa7289d56b12e520eb
openwrt-bcm53xx-generic-meraki_mx65w-squashfs.sysupgrade.bin
  sha256 d6211095cf1fdeba9003d3f6299ed612aeb49aabe9f66b6495810219c827a871
```

Both include PoE (`bcm59111`), LuCI, and USB storage, so the device stays
usable while you collect data.

Packages added over the normal MX65 build:

- `kmod-brcmfmac` (with `CONFIG_BRCMFMAC_PCIE=y`)
- `kmod-brcmutil`
- `kmod-cfg80211`

That yields `brcmfmac.ko` plus the `brcmfmac-bca.ko`, `brcmfmac-cyw.ko` and
`brcmfmac-wcc.ko` protocol variants.

## Running the probe

You do **not** need to flash this. Boot it from the USB stick to leave your
installed firmware untouched. The probe runs entirely in RAM, so nothing is
written to NAND and a simple power cycle returns you to your installed
firmware.

### 1. The filename is not optional

This is the part that catches people. U-Boot hardcodes the initramfs name:

```
initramfs_filename=openwrt-bcm53xx-generic-meraki_mx65-initramfs.bin
usb_checkboot=if test $enable_usb_boot = 1; then usbload; fi
usbload=usb start; fatload usb 0:1 ${loadaddr} ${initramfs_filename};
        bootm ${loadaddr}#${config_dts}
```

There is no `meraki_mx65w` entry anywhere. **A file named
`...meraki_mx65w-initramfs.bin` will never be found and the router will fall
back to the wrong image.** The probe initramfs has to sit at the canonical
`meraki_mx65` name:

```sh
# stage the probe under the name U-Boot actually looks for
cp openwrt-bcm53xx-generic-meraki_mx65w-initramfs.bin \
   /mnt/dos/openwrt-bcm53xx-generic-meraki_mx65-initramfs.bin
```

Verify it afterwards - the checksum must be the probe's, not the old
recovery image's:

```sh
cd /mnt/dos && sha256sum openwrt-bcm53xx-generic-meraki_mx65-initramfs.bin
# 50d215c7f6e3e8a583ea6104eb1f527354aa7f69021570aa7289d56b12e520eb
```

If you displace an image already at that name, keep it under another name
rather than overwriting it.

### 2. The DTB does come from the probe

U-Boot boots with `bootm ${loadaddr}#config@3`, which sounds like it would
override the device tree. It does not - it selects a configuration *within*
the image, and each image carries its own:

```
$ dumpimage -l openwrt-bcm53xx-generic-meraki_mx65w-initramfs.bin
 Image 1 (fdt-1)
  Description:  ARM OpenWrt meraki_mx65w device tree blob
 Default Configuration: 'config@3'
```

Extracted from each image's `config@3`:

```
mx65  : model = "Cisco Meraki MX65"   status okay x7   disabled x14
probe : model = "Cisco Meraki MX65W"  status okay x9   disabled x12
```

So the probe really does boot with PCIe enabled, despite carrying the `mx65`
filename.

### 3. Boot it

Plug the stick into the router and:

1. Hold **reset** while powering on, about 15 seconds (orange, then white
   blink-blink)
2. Release, wait about 15 seconds for green
3. It boots the MX65W initramfs

If it does not boot, copy the file again - a truncated write is the usual
cause.

### 4. Collect the data

```sh
# The question: are the radios there?
lspci -nn
ls /sys/bus/pci/devices/

# Did the host bridge come up at all?
dmesg | grep -i pcie

# Did brcmfmac bind to anything?
dmesg | grep -i brcmfmac
ls /sys/bus/pci/drivers/brcmfmac/ 2>/dev/null

# Kernel module state
lsmod | grep -E "brcmfmac|pcie"

# PCIe link status
for d in /sys/bus/pci/devices/*/; do
  echo "== $d"
  cat $d/vendor $d/device 2>/dev/null
  cat $d/current_link_speed $d/current_link_width 2>/dev/null
done
```

## Interpreting the results

**A `14e4:43xx` device appears.** Confirms the hardware is present. `brcmfmac`
will still fail on the missing firmware blob, but the device ID tells us
exactly which chip revision is fitted - genuinely useful for anyone writing
future support.

**A device appears with an unfamiliar vendor or device ID.** More interesting
than expected. It would mean the radio is not a part we assumed, and a
different driver path might apply.

**`dmesg` shows PCIe link failures, or nothing enumerates.** The radios need
clock or power sequencing that the upstream device tree does not describe.
This is the expected outcome if the hardware is fitted but not initialised by
this minimal configuration.

**`brcmfmac` loads and binds.** Check `dmesg` for the firmware error. A
"firmware not found" message confirms the driver works but the blob does not
exist - the outcome predicted in [WIFI.md](WIFI.md).

## After probing

Nothing was written to NAND, so just power-cycle to get your installed
firmware back. No revert step is needed.

There is deliberately no probe sysupgrade image. `sysupgrade` validates the
running board against the image metadata, and it refuses:

```
$ sysupgrade -T openwrt-bcm53xx-generic-meraki_mx65w-squashfs.sysupgrade.bin
upgrade: Device meraki,mx65 not supported by this image
upgrade: Supported devices: meraki,mx65w
Image check failed.
```

The router's installed board is `meraki,mx65`, so the check fails on the
platform string alone. Overriding it with `sysupgrade -F` would write a
firmware whose board metadata does not match the running system, which is a
poor trade for a diagnostic that costs nothing to run from RAM.

To go back to a normal USB boot with your production image, restore the
canonical name:

```sh
cp current-initramfs.bin \
   /mnt/dos/openwrt-bcm53xx-generic-meraki_mx65-initramfs.bin
```

The stick is laid out so both fallbacks survive:

| File | What it is |
|---|---|
| `openwrt-bcm53xx-generic-meraki_mx65-initramfs.bin` | Canonical slot - U-Boot only reads this name |
| `mx65w-probe-initramfs.bin` | MX65W probe, for identification |
| `current-initramfs.bin` | Production MX65 build (r0-7670f36) |
| `mx65-r31914-fallback-initramfs.bin` | Older r31914 recovery image, still good |
| `current-sysupgrade.bin` | Production sysupgrade |
| `openwrt-bcm53xx-generic-meraki_mx65-squashfs.sysupgrade.bin` | r31914 sysupgrade |

## If the radios do show up

Even a successful enumeration leaves the firmware wall. To go further you
would need:

1. Broadcom firmware blobs for the exact chip ID - not published
2. A driver that speaks its FullMAC register interface - undocumented
3. Kernel 6.18 compatibility for whatever you build

At that point an external AP or USB adapter remains the pragmatic answer.

## Building this yourself

The device profile addition and config are captured under
`patches/mx65w-probe/`. Apply the diff to
`target/linux/bcm53xx/image/Makefile`, then use
`patches/mx65w-probe/config` as `.config`.

One thing to watch: `kmod-cfg80211` must be selected or nothing wireless
builds. `CONFIG_PACKAGE_kmod-cfg80211=y` in the target config is what pulls in
the kernel-side `CONFIG_CFG80211`, and `CONFIG_BRCMFMAC_PCIE=y` selects the
PCIe bus. Without cfg80211 the kernel `config BRCMFMAC` cannot even be
offered, since it `depends on CFG80211`, and `brcmfmac.ko` silently never
appears.

Confirm the driver landed rather than assuming it did:

```sh
# module was actually compiled
find build_dir -name 'brcmfmac*.ko'

# and is actually inside the image
dumpimage -T flat_dt -p 1 -o /tmp/dtb <initramfs>.bin
dtc -I dtb -O dts /tmp/dtb | grep -c 'status = "okay"'
```