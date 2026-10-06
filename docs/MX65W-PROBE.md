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
installed firmware untouched.

### 1. Put the initramfs on the stick

The file must keep its exact name - U-Boot matches on that string:

```sh
cp openwrt-bcm53xx-generic-meraki_mx65w-initramfs.bin /mnt/dos/
```

### 2. Boot it

Plug the stick into the router and:

1. Hold **reset** while powering on, about 15 seconds (orange, then white
   blink-blink)
2. Release, wait about 15 seconds for green
3. It boots the MX65W initramfs

If it does not boot, copy the file again - a truncated write is the usual
cause.

### 3. Collect the data

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

Return to the normal MX65 firmware whenever you like:

```sh
sysupgrade -n /path/to/openwrt-bcm53xx-generic-meraki_mx65-squashfs.sysupgrade.bin
```

The `-n` wipes configuration, which is what you want when moving between
profiles. Your `192.168.88.0/24` LAN settings and the firewall rules would
otherwise be carried across and then migrated, which is rarely what you want
during a hardware experiment.

Alternatively, flash the initramfs without installing anything and simply
power-cycle when finished. Nothing is written to NAND that way.

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