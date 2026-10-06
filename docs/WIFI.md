# Wireless on the MX65W

## Summary

**The MX65W's built-in WiFi cannot be made to work on OpenWrt.** The radios are
not supported by any in-tree driver, and they are not even detected by the
kernel. Use an external access point.

This is a hardware limitation, not a packaging problem in this project.

## What the hardware actually is

The MX65W adds two **Broadcom BCM43520KMLG** chipsets to the otherwise
identical MX65. These are FullMAC parts on an internal bus.

Checking a live MX65W confirms the chips do not enumerate at all:

```sh
ls /sys/bus/pci/devices/          # 0 devices - no PCIe wireless controller
ls /sys/bus/mmc/devices/          # no MMC bus either
```

So there is nothing for a driver to bind to. This is expected: the MX65W's
wireless was never supported upstream, and OpenWrt's `bcm53xx` target defines
no wifi packages for `meraki_mx65`.

## Why the obvious drivers do not help

| Driver | Covers BCM43520? | Why not |
|---|---|---|
| `brcmfmac` | No | Linux's `wireless.docs.kernel.org` driver list for `brcmsmac`/`brcmfmac` does not include BCM43520. It is a FullMAC part requiring firmware blobs that were never published for it. |
| `b43` | No | `b43` covers Broadcom SoftMAC chipsets only (BCM43xx). FullMAC parts like BCM43520 are out of scope; the kernel docs list BCM4352 explicitly as unsupported by `b43`. |
| `broadcom-sta` (`wl`) | Not portable | A closed-source binary kernel module. It is not in mainline, not in OpenWrt, and Broadcom never released a version for this SoC or this kernel series (6.18). |
| `brcmsmac` | No | The `bcm53xx` in-tree support is for the Ethernet switch, not wireless. |

Even if a driver were found, it would need `brcm/bcm43520*` firmware blobs,
which do not exist in `linux-firmware` for this chip.

## Recommendation

**Use a MikroTik hAP or similar as the access point.**

This is a good trade for an MX65W specifically:

- A dedicated AP is what you want anyway. It sits where the clients are,
  rather than pinned to wherever the MX65W happens to sit.
- MikroTik hAP ax2/ac ranges are inexpensive and provide stable, well-supported
  OpenWrt builds if you prefer to run OpenWrt on the AP too.
- It gives you proper 802.11ax, which the MX65W could not offer regardless.

Wire the MX65W as a wired router and let the AP handle wireless:

```
   internet
      |
  MX65W wan1
  MX65W lan3 ---- switch ---- clients
  MX65W lan4 ---- MikroTik hAP (PoE in, AP mode)
  MX65W lan11/12 -- PoE devices, if the PSE works for you
```

## PoE alternative

Since you are considering a MikroTik anyway: **MikroTik routers with PoE-out
are a more reliable power source than the MX65W's experimental PSE.**

Devices like the hEX S, RB5009, or CRS series can supply PoE natively. If you
need PoE for cameras or APs, a MikroTik hEX will do it properly, and it removes
the only unproven component from this build.

That is a reasonable trade: keep the MX65W for routing and firewalling where its
performance is more than adequate, and delegate PoE to hardware that does it
properly.

## If you must use the MX65W radios

You would need to:

1. Find or reverse-engineer a driver for BCM43520.
2. Obtain firmware blobs Broadcom never published.
3. Patch it against kernel 6.18, a kernel it was never written for.

Treat this as a research project, not a task. There is no realistic path to a
working, supported wifi stack on this hardware.