# PoE support on the Meraki MX65

## The hardware

The MX65 has two PoE+ ports (`lan11` and `lan12`) rated at 30 W each, for a
total budget of 60 W. Power is supplied by a **Broadcom BCM59111** PSE
(Power Supply Equipment) controller, which sits on the I2C bus at address
`0x21` and reports a 60 W (`60000` mW) budget.

The PSE is a relatively simple microcontroller: on power-up it must be fed a
firmware image over I2C before it will negotiate power with any connected
device. This is why simply providing a sysfs interface is not enough - the
driver has to upload that firmware first.

Upstream OpenWrt has no driver for this chip, so a stock install leaves both PoE
ports completely dead.

## What this project adds

Three pieces, all in `target/linux/bcm53xx`:

### 1. The driver

`files/drivers/hwmon/bcm59111.c`, derived from the PoE driver in Cisco's
MX64/MX65 GPL firmware release. It:

- Uploads the PSE firmware after reset
- Reads chip identity and parameters
- Registers a `poe` class device with `poe0`
- Exposes one device per port under `sys_ports`
- Handles detection, classification, and power enable/disable

Because the driver is called "hwmon" in kernel terms but registers its own
`poe` class, port state appears under **`/sys/class/poe/`**, not
`/sys/class/hwmon/`. This trips people up, so it is worth stating plainly.

### 2. The device-tree node

`patches-6.18/802-ARM-dts-NSP-add-BCM59111-to-MX65.patch` adds the controller to
`bcm958625-meraki-alamo.dtsi`:

```dts
&i2c0 {
	bcm59111@21 {
		compatible = "brcm,bcm59111";
		pagesize = <32>;
		reg = <0x21>;
		ports = <2>;
		port_base = <0>;
		max_power_mw = <60000>;
	};
};
```

`ports` and `max_power_mw` come from the hardware and match what the chip reports
at runtime.

### 3. Package wiring

`kmod-hwmon-bcm59111` in `modules.mk`, plus `DEVICE_PACKAGES +=` in
`image/Makefile` so it is installed automatically on `meraki_mx65`.

The module autoloads at priority 60 via `/etc/modules.d/60-hwmon-bcm59111`.

## Reading port state

```sh
ls /sys/class/poe/          # poe0, port0, port1, sys_ports
cat /sys/class/poe/poe0/power_budget   # 60000 (mW)
```

Per port:

```sh
for p in port0 port1; do
  echo "== $p"
  for a in enabled status class mode power millijoules overload underload denied; do
    printf "  %-12s %s\n" "$a" "$(cat /sys/class/poe/$p/$a)"
  done
done
```

### Attributes

| Attribute | Meaning |
|---|---|
| `enabled` | 1 = port enabled, 0 = disabled. Writable. |
| `status` | Detection state: `unknown`, `short`, `cpd_high`, `rsig_low`, `good`, `rsig_high`, `open`. `good` means a valid device is present. |
| `class` | Detected class, as a string: `unknown`, `1`, `2`, `3`, `4`, `reserved`, `0`, `overcurrent` |
| `mode` | `UNK` (nothing attached), `AT` (802.3at), `AF` (802.3af), `OC` (overcurrent), `RESV` |
| `power` | Measured power draw in **milliwatts** |
| `millijoules` | Cumulative energy in millijoules, accumulated by the driver. Resets on driver reload or reboot. |
| `overload` / `underload` | Fault flags, matched against detect bits |
| `denied` | Port refused power (class/exhausted budget) |

### Determining whether a device is attached

`status` is the direct answer: `good` means the PSE has detected a valid
device. `luci-app-poe` uses that as its primary signal and falls back to the
`mode` field and measured power as a cross-check, since a port can be
classified and still be delivering nothing.

### Device-level fault flags

```sh
cat /sys/class/poe/poe0/failed_fet    # 0 = healthy
cat /sys/class/poe/poe0/failed_temp   # 0 = healthy
cat /sys/class/poe/poe0/uvlo_main     # undervoltage on main rail
cat /sys/class/poe/poe0/uvlo_vcc      # undervoltage on VCC
```

All four should read `0`.

## Fixed driver bugs

Three defects were found by comparing the driver source against live hardware.
All three are now fixed; the history below is kept because each one silently
reported a wrong value rather than failing loudly, which is the reason to record
them.

### 1. `status` was a duplicate of `enabled` (fixed)

```c
DEV_SHARED_RD(enabled, POE_STATPWR_REG, POE_NO_OFFSET, POE_SINGLE_BIT, POE_STATPWR_PORT_EN_OFF);
DEV_SHARED_RD(status,  POE_STATPWR_REG, POE_NO_OFFSET, POE_SINGLE_BIT, POE_STATPWR_PORT_EN_OFF);
```

Same register, same mask, same bit offset. `status` only ever echoed the enable
bit. On live hardware it read `1` on a port running a 3 W load.

It now reads the detect field of `POE_STATP`, which `overload` and `underload`
were already reaching:

```c
DEV_STR_ARRAY_RD(status, detect_state, POE_STATP_BASE, POE_STATP_OFFSET,
		 POE_STATP_DETECT_BITS, POE_STATP_DETECT_OFFSET);
```

`DEV_STR_ARRAY_RD` is a new macro. The existing `DEV_STR_RD` derives its string
table from the attribute name, so it can only report a global array that happens
to share that name; `status` needs to report `detect_state[]`.

### 2. `detect_state[]` was dead, undersized and mislabelled (fixed)

```c
char *detect_state[] = { "unknown", "short", "cpd_high", "rsig_low", "good", "open" };
```

Six strings for seven `DETECT_*` values, so `DETECT_OPEN` (0x6) read past the end
of the array, and index 5 was labelled `"open"` when it is `DETECT_RSIG_HIGH`.

This was dead code, so nothing was broken at runtime - but fixing bug 1 without
fixing this would have turned a wrong value into an out-of-bounds read. The
array now matches the enum exactly:

```c
char *detect_state[] = { "unknown",  "short", "cpd_high",
			 "rsig_low", "good",  "rsig_high",
			 "open" };
```

The detect field is three bits wide, so the printed formatter's `ARRAY_SIZE`
guard covers the remaining value (7) and reports `ERR`.

### 3. `millijoules` was neither millijoules nor cumulative (fixed)

```c
static ssize_t millijoules_show(...)
{
	s64 watts = calculate_port_power_usage(dev->devt);
	uint32_t t = (jiffies - poe.last_joule_time[dev->devt]);
	poe.last_joule_time[dev->devt] = jiffies;
	return scnprintf(buf, PAGE_SIZE, "%llu\n", watts * t);
}
```

Two separate faults. `calculate_port_power_usage()` returns **milliwatts**, and
`t` is in **jiffies**, so the result was `mW x jiffies` with no conversion to any
energy unit - off by a factor of 1000/HZ. For one second at 3.084 W it reported
308400 instead of 3084 mJ. And because `last_joule_time` was reset inside the
show path, any period during which nobody read the attribute contributed
nothing, so the figure depended on polling frequency rather than consumption. It
was observed jumping from `80105333328` to `108865200` with nothing unplugged.

There is no hardware energy register to read - the counters at 0x60-0x63 are
fault counters (invalid signature, power denied, over/short, MPS). So the total
is accumulated in software, sampled on a one-second timer rather than on read:

```c
poe.energy_mj[i] += div64_u64(mw * elapsed_ms, 1000);
```

The timer keeps running whether or not anyone reads the attribute, so the total
no longer depends on who is polling. It is held in RAM and therefore resets on
driver reload or reboot; that is inherent to not having a hardware counter, and
is stated rather than hidden.

## The LuCI page

PoE used to be reachable only through `sysfs`. `luci-app-poe` adds
**Network -> PoE Ports**, showing the controller summary (budget, total draw,
fault flags) and a per-port table with a power toggle that confirms before
cutting power to an attached device.

It is built on a small ucode rpcd object rather than reading `sysfs` from the
browser:

```sh
ubus call poe status '{}'
ubus call poe set '{"port":1,"enabled":0}'
```

That keeps all `sysfs` access in one place, returns a single consistent
snapshot instead of a dozen `fs.readfile` round-trips, and means the toggle is
governed by an rpcd ACL (`read` for `status`, `write` for `set`) rather than
general `fs` write access.

Two behaviours worth knowing:

- **Enabling an empty port does not latch.** In automatic mode the PSE only
  asserts the enable bit once a device is detected, so `set` can report
  `requested: 1` with `actual: 0`. The page shows actual state, so the
  checkbox springs back. That is hardware behaviour, not a UI bug.
- **The page polls every 5 seconds** to keep the power readings live.

## Enabling a port

The driver sets `OP_MODE_AUTO` on all ports after firmware upload, so ports
start in automatic mode and enable themselves when a device is detected. To
control a port explicitly:

```sh
echo 1 > /sys/class/poe/port0/enabled
echo 0 > /sys/class/poe/port0/enabled
```

Or through the web UI, or:

```sh
ubus call poe set '{"port":0,"enabled":0}'
```

Verify with a real PoE load, not just the attribute values. A port with
`mode` other than `UNK` and non-zero `power` is the meaningful confirmation.

## Port mapping

`lan11` and `lan12` are the PoE+ ports. They are on `sw1` in the switch layout:

```
sw1 -- lan8 lan9 lan10 lan11 lan12
                  ^^^  ^^^  PoE+
```

Because `port_base` is 0 in the device tree, `port0` corresponds to `lan11` and
`port1` to `lan12`. This is confirmed on live hardware: a Grandstream GWN7610
attached to `lan11` reports as `port0`, drawing 3.08 W at class 4.

## Kernel compatibility notes

The original driver targeted kernel 6.6. Porting to current kernels (6.18 at the
time of writing) required these changes, all applied in
`patches/001-modernisation.patch`:

| Change | Reason |
|---|---|
| `class_create("poe")` | `class_create()` lost its `THIS_MODULE` argument |
| `void bcm_poe_remove()` | `__devexit` and `remove_new` were removed |
| `.remove = bcm_poe_remove` | I2C `.remove` is now a void callback |
| `bcm_poe_probe(cl)` | OF-based probe takes no `i2c_device_id` |
| `of_match_table` added | Required for device-tree binding |
| `ktime_get_real_seconds()` | `CURRENT_TIME_SEC` removed |
| Dropped `__devinitdata` | Removed from the kernel |
| `0222`/`0666` to `0220`/`0664` | Sysfs write perms tightened upstream |
| Removed forced shutdown before FW load | Caused needless port renegotiation |

Keeping the sysfs permissions tight matters: the driver exposes power control,
and world-writable attributes would let any local user cut power to your
attached devices.

## Known issues

- **Not upstream.** This driver has never been merged into OpenWrt, so it
  receives no review and carries no support guarantee.
- **PoE does not persist across a full power cycle reliably** on some units;
  re-check port state after reboot.
- **Per-port power limits cannot be set** through the current sysfs interface,
  only the global budget is exposed.
- **Thermal shutdown** behaviour is untested under sustained full load. Test
  before deploying anything that matters.
- **Energy totals are RAM-only** and reset on driver reload or reboot. The
  BCM59111 has no energy register; the counters it does have are fault counters.
- **Raw register access is exposed** at `/sys/class/poe/poe0/reg` and
  `reg_arg`. These bypass every safety check in the driver. `luci-app-poe`
  deliberately ignores them.