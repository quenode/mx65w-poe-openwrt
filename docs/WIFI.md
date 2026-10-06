# Wireless on the MX65W

## Summary

**The MX65W's built-in WiFi cannot be made to work on OpenWrt.** Use an
external access point.

This is a hardware and firmware-availability limitation, not something this
project can package around. The investigation below is recorded in full because
the conclusion is counter-intuitive in places: the radios *are* on PCIe, and the
PCIe host bridge *is* compiled into this kernel. The wall is elsewhere.

## What the hardware actually is

The MX65W adds two **Broadcom BCM43520KMLG** chipsets to the otherwise
identical MX65.

Upstream OpenWrt already models the difference. `bcm958625-meraki-mx65w.dts`
differs from `bcm958625-meraki-mx65.dts` by exactly one thing:

```
&pcie0 {
	status = "okay";
};

&pcie1 {
	status = "okay";
};
```

So the wireless radios sit behind the Broadcom iPROC PCIe controllers. The MX65
leaves both controllers `disabled`, because it has no radios to serve.

### Why your router shows nothing

OpenWrt builds a single profile, `meraki_mx65`, for both variants. That device
tree leaves the PCIe controllers off, so on a live MX65W you see:

```sh
tr "\0" "\n" < /proc/device-tree/model
# Cisco Meraki MX65

tr -d "\0" < /proc/device-tree/pcie@18012000/status
# disabled

ls /sys/bus/pci/devices/
# empty
```

That empty listing is the reason it looks like there is no wireless hardware.
The bus was never enabled.

## The parts that DO work

Worth stating plainly, because it narrows the problem considerably:

- `CONFIG_PCIE_IPROC=y` is already set in the `bcm53xx` kernel config.
- The `brcm,iproc-pcie` host-bridge driver is present in the kernel tree
  (`drivers/pci/controller/pcie-iproc-bcma.c`).

So the host bridge is compiled in and just needs enabling. Enumerating the bus
is therefore feasible.

## Where it stops

Two independent walls, either of which is fatal on its own.

### Wall 1: no driver recognises BCM43520

Every PCIe device ID `brcmfmac` will bind to, read directly from
`brcmfmac/pcie.c`:

```
4350  4354(raw)  4355  43567  4356  43570  43570(raw)  4358
43596  4359  43602(2G/5G/raw)  4364  4365(2G/5G)  4366(2G/5G)
4371  43752  4377  4378  4387  54591(cypress)
```

BCM43520 is not among them. Nor is BCM4352 - the similarly-named chip you may
have seen referenced. The firmware blobs it looks for follow the same pattern:

```
brcmfmac4350-pcie   brcmfmac4355-pcie   brcmfmac4356-pcie
brcmfmac4358-pcie   brcmfmac4359-pcie   brcmfmac43602-pcie
brcmfmac4365b-pcie  brcmfmac4366b-pcie  brcmfmac4371-pcie  ... etc
```

There is no `brcmfmac43520-*.bin` in `linux-firmware`, because Broadcom never
published firmware for this part.

### Wall 2: the GPL release contains no wireless driver

Cisco's MX64/MX65 GPL release was checked in full
(`wired-14-39-mx64-20190426.tar.bz2`, 98 MB):

```sh
grep -ril "43520" .    # zero matches across the entire tree
```

The MX64/MX65 target inside is `wired-arm-nsp-3.4`. Its kernel config has
`CONFIG_PCI=y` but no wireless driver of any kind.

The wireless code that *is* in the release belongs to the MR-series access
points, and is Atheros code from the pre-mac80211 era:

| Package | What it is |
|---|---|
| `madwifi` | Atheros madwifi, 802.11g-era |
| `ieee80211-dscape` | Atheros Dscape, same generation |
| `wlcompat` | A 2005 **MIPS** Wext-API shim over `wlioctl` - not a driver |

This is expected. Cisco's GPL obligation covers GPL-licensed code. Broadcom's
`wl` driver is proprietary, so it was never published.

## Could we decompile the stock firmware?

This was investigated and does not help, for two reasons.

**The stock firmware is not public.** Meraki appliances download firmware from
Cisco's cloud, and the endpoints (`downloads.meraki.net`, and the Meraki
community firmware feed) require cloud authentication. There is no anonymous
MX65W firmware image to pull apart.

**Even with it, the result would not be usable.** A stock firmware image would
contain a `wl.ko` built for Meraki's own kernel (2.6.x/3.4-era, per the GPL
tree), for a proprietary Broadcom kernel module whose source was never
published. Decompiling that gives you a binary blob for a kernel that does not
exist on this device. It cannot be loaded on OpenWrt kernel 6.18, and there is
no source to port.

## Could we write a new driver?

Not a working one. A driver needs three things:

1. **A bus to bind to.** Achievable - enable `pcie0`.
2. **Firmware for the chip.** Blocked - never published for BCM43520.
3. **The register interface.** Blocked - undocumented, reverse-engineering
   would be required, and this is a FullMAC part whose behaviour lives in that
   missing firmware.

Step 1 alone produces a `brcmfmac` module that enumerates the device and then
fails to find a firmware blob. That is the whole story: **the missing
ingredient is not code, it is Broadcom firmware.**

For completeness, `b43` and `brcmsmac` are also non-starters: `b43` covers
SoftMAC parts only, and `brcmsmac` in this tree drives the Ethernet switch, not
wireless.

## Recommendation

**Use a MikroTik hAP or similar as the access point.**

- A dedicated AP is what you want anyway; it belongs where the clients are.
- It provides stable, well-supported OpenWrt builds if you prefer to run OpenWrt
  on the AP as well.
- It offers proper 802.11ax, which the MX65W could not deliver regardless.

Wire the MX65W as a wired router:

```
   internet
      |
  MX65W wan1
  MX65W lan3 ---- switch ---- clients
  MX65W lan4 ---- MikroTik hAP
  MX65W lan11/12 -- PoE devices, if the PSE proves out
```

## PoE alternative

Since you are considering a MikroTik anyway: **MikroTik routers with PoE-out
are a more reliable power source than this experimental PSE.**

Devices such as the hEX S, RB5009 and CRS series supply PoE natively. If you
need PoE for cameras or APs, that solves the problem properly and removes the
only unproven component from this build.

Keep the MX65W for routing and firewalling, where its performance is more than
adequate, and delegate wireless and PoE to hardware that does both properly.

## If you want the USB-adapter route instead

Avoid Broadcom. Adapters based on these chips have working drivers on this
kernel:

- **MT7612U** (`mt76x2u`) - dual band, AC
- **MT7610U** (`mt76x0u`) - dual band, N
- **MT7921U** (`mt7921u`) - Wi-Fi 6

## For the curious: probing the PCIe bus anyway

Enabling the bus is a legitimate experiment even though it cannot produce
working WiFi. It would confirm whether the radios are present on your specific
unit and reveal their real PCI device ID, which is genuinely useful
information for the community.

It requires a build with the MX65W device tree (or two lines added to the MX65
one), plus `kmod-brcmfmac-pcie` installed. Expect one of three results:

- **A `14e4:43xx` device appears** - confirms the hardware; `brcmfmac` will
  still fail on the missing firmware
- **A device with an unfamiliar ID appears** - useful new information
- **The link fails to train** - the radios need clock or power sequencing the
  device tree does not describe

This is diagnostic only, and would be a separate build rather than a change to
the working image.