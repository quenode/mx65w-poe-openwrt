# v1.1.0

Bug-fix release for the PoE driver. Same OpenWrt revision as v1.0.0
(`r0-7670f36`, kernel 6.18.55) — **only the driver differs**, so upgrading is
otherwise identical.

**Upgrading is recommended.** In v1.0.0 the `status` attribute could not tell
you whether a device was attached, and `millijoules` reported a meaningless
number that changed depending on how often you read it.

```sh
sysupgrade openwrt-bcm53xx-generic-meraki_mx65-squashfs.sysupgrade.bin
```

Your configuration is preserved; no need for `-n`.

## What was wrong, and what changed

All three bugs shared a characteristic worth naming: **they reported a wrong
value rather than failing.** Nothing logged an error, nothing crashed. They
were only discoverable by reading the driver source and comparing it against
real hardware.

### `status` could not report detection

```c
DEV_SHARED_RD(enabled, POE_STATPWR_REG, POE_NO_OFFSET, POE_SINGLE_BIT, POE_STATPWR_PORT_EN_OFF);
DEV_SHARED_RD(status,  POE_STATPWR_REG, POE_NO_OFFSET, POE_SINGLE_BIT, POE_STATPWR_PORT_EN_OFF);
```

Same register, same mask, same bit offset — `status` only ever echoed the
enable bit. A script asking "is a device attached?" got a wrong answer.

It now reads the detect field of `POE_STATP` and reports:

```
unknown  short  cpd_high  rsig_low  good  rsig_high  open
```

### `detect_state[]` was undersized

Six strings for seven `DETECT_*` values, so `DETECT_OPEN` (0x6) read past the
end of the array, and index 5 was labelled `"open"` when it is
`DETECT_RSIG_HIGH`.

This had to be fixed *first*: wiring up `status` without correcting the array
would have converted a wrong value into an out-of-bounds read.

### `millijoules` was neither millijoules nor cumulative

```c
s64 watts = calculate_port_power_usage(dev->devt);   /* milliwatts */
uint32_t t = (jiffies - poe.last_joule_time[dev->devt]);  /* jiffies */
poe.last_joule_time[dev->devt] = jiffies;             /* reset on read */
return scnprintf(buf, PAGE_SIZE, "%llu\n", watts * t);
```

Two faults. `power_mW × jiffies` with no conversion — wrong by a factor of
`1000/HZ`, so one second at 3.084 W reported **308400** instead of 3084 mJ.
And because the timestamp reset on every read, any period during which nobody
read the attribute contributed nothing, making the figure depend on polling
frequency rather than consumption.

There is no hardware energy register on this chip — the counters at 0x60–0x63
are fault counters (invalid signature, power denied, over/short, MPS). The
total is therefore accumulated in software on a one-second timer, so it no
longer depends on who is polling.

It lives in RAM and resets on driver reload or reboot. That is inherent to
having no hardware counter, and is stated rather than hidden.

## Verified on hardware

Deployed with `sysupgrade` to an MX65W with a Grandstream GWN7610 on `lan11`:

| | before | after |
|---|---|---|
| `port0/status` | `1` | `good` |
| `port0/millijoules` | `34263927712` | climbing from 0, in real mJ |
| `port1/status` | `1` | `open` |

`port1` reading `open` is `DETECT_OPEN` (0x6) — index 6, the entry that was out
of bounds. Real hardware now exercises the corrected array.

Energy was cross-checked over 60 seconds against an independent trapezoidal
integration sampled at the same one-second resolution the driver uses:
**267859 mJ from the driver versus 269513 mJ integrated, ratio 0.9939.**

> An earlier comparison sampled every 5 seconds and produced 0.933, which
> looked like a failure. It was sampling bias — the AP draws between roughly
> 4300 and 5800 mW, and 5-second spot samples cannot represent a 1-second
> integral. Matching the driver's resolution removed the discrepancy. Recorded
> because that misleading number is easy to misread as a driver fault later.

The LuCI page at *Network → PoE Ports* now shows the real detection state and a
cumulative energy total:

```
lan11   DETECTED   Class 4   AT   4.92 W   1069537 mJ
lan12   OPEN       unknown   UNK  0.00 W        0 mJ
```

## Downloads

Same filenames and layout as v1.0.0.

```
meraki_mx65-initramfs.bin             boot from USB, RAM only
meraki_mx65-squashfs.sysupgrade.bin   install to NAND   <- use this
meraki_mx65w-initramfs.bin            diagnostic, RAM only
meraki_mx65w-squashfs.sysupgrade.bin  diagnostic, install to NAND
```

Verify with the `sha256sums` asset. CI re-checks the published checksums and
confirms each initramfs is a structurally valid FIT image.

The MX65W profile remains **diagnostic only** — see
[docs/WIFI.md](https://github.com/quenode/mx65w-poe-openwrt/blob/master/docs/WIFI.md).
The onboard BCM43520 radios cannot be used; use an external AP.

## Still known

- Energy totals reset on driver reload or reboot.
- PoE may not persist across a full power cycle on every unit.
- Thermal shutdown under sustained full load is untested.
- Per-port power limits cannot be set; only the global budget is exposed.

## Licence

GPL-2.0-only. See [LICENSE](https://github.com/quenode/mx65w-poe-openwrt/blob/master/LICENSE),
with third-party attribution in [NOTICE](https://github.com/quenode/mx65w-poe-openwrt/blob/master/NOTICE).

Cisco, Meraki and MX65 are trademarks of Cisco Systems, Inc. This project is
not affiliated with, sponsored by, or endorsed by Cisco Systems, Inc.