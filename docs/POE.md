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
| `enabled` | 1 = port enabled, 0 = disabled |
| `status` | 0 = no device, 4 = good, 6 = open circuit |
| `class` | Detected class: 0-4 (class of power), 6 = class 0, 7 = overcurrent |
| `mode` | `AT` (802.3at), `AF` (802.3af), `OC` (overcurrent), `UNK` = nothing attached |
| `power` | Measured power draw |
| `millijoules` | Energy counter |
| `overload` / `underload` | Fault flags |
| `denied` | Port refused power (class/exhausted budget) |

### Device-level fault flags

```sh
cat /sys/class/poe/poe0/failed_fet    # 0 = healthy
cat /sys/class/poe/poe0/failed_temp   # 0 = healthy
cat /sys/class/poe/poe0/uvlo_main     # undervoltage on main rail
cat /sys/class/poe/poe0/uvlo_vcc      # undervoltage on VCC
```

All four should read `0`.

## Enabling a port

The driver sets `OP_MODE_AUTO` on all ports after firmware upload, so ports
start in automatic mode and enable themselves when a device is detected. To
control a port explicitly:

```sh
echo 1 > /sys/class/poe/port0/enabled
echo 0 > /sys/class/poe/port0/enabled
```

Verify with a real PoE load, not just the attribute values. A port reading
`status 4` and `class 3` with non-zero `power` is the meaningful confirmation.

## Port mapping

`lan11` and `lan12` are the PoE+ ports. They are on `sw1` in the switch layout:

```
sw1 -- lan8 lan9 lan10 lan11 lan12
                 ^^^  ^^^  PoE+
```

Because `port_base` is 0 in the device tree, `port0` corresponds to `lan11` and
`port1` to `lan12`. Confirm by attaching a device to one port and checking which
`portN` reports a detection status.

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