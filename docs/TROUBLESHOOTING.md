# Troubleshooting

## LuCI returns an empty page

**Symptom:** Browsing to the router gives a blank response, or `curl` returns
HTTP 000 / a zero-byte body, while `uhttpd` is clearly running and listening.

**Cause:** This is almost always a stale `lua_prefix` in `/etc/config/uhttpd`:

```
option lua_prefix '/cgi-bin/luci=/usr/lib/lua/luci/sgi/uhttpd.lua'
```

That setting belongs to the **Lua** implementation of LuCI. Current OpenWrt
(snapshot builds from 2025 onward) ships **ucode** LuCI, where
`/cgi-bin/luci` is a real executable script and no `lua_prefix` exists. The
stale mapping hijacks the request and uhttpd replies with nothing.

**Fix:**

```sh
uci delete uhttpd.main.lua_prefix
uci commit uhttpd
/etc/init.d/uhttpd restart
```

**How to confirm it is this problem rather than something else:**

```sh
# If the target does not exist, the setting is stale:
ls /usr/lib/lua/luci/sgi/uhttpd.lua

# LuCI's own dispatcher works, proving the backend is fine:
cd / && REQUEST_METHOD=GET REQUEST_URI=/cgi-bin/luci HTTP_HOST=127.0.0.1 \
  /www/cgi-bin/luci
```

That last command should print a `Status: 403 Forbidden` response with
`x-luci-login-required: yes`. The 403 is **correct** - it means LuCI is working
and asking you to log in.

**How this arises:** it only happens when you carry `/etc/config/uhttpd` across
a major upgrade. A plain `sysupgrade` preserving config, or a cross-version
migration like the one in this project's history, will preserve the old
setting.

## LuCI is unreachable from another machine

The WAN firewall zone defaults to `input REJECT`, so only ports you explicitly
allow are reachable from the WAN side. If you can reach the router over SSH but
not HTTP, that is the firewall, not LuCI.

Allow web access from your management network only:

```sh
uci add firewall rule
uci set firewall.@rule[-1].name='Allow-LuCI-from-99'
uci set firewall.@rule[-1].src='wan'
uci set firewall.@rule[-1].src_ip='192.168.99.0/24'
uci set firewall.@rule[-1].proto='tcp'
uci set firewall.@rule[-1].dest_port='80 443'
uci set firewall.@rule[-1].target='ACCEPT'
uci commit firewall
/etc/init.d/firewall restart
```

Prefer a single host over a whole subnet where possible:

```sh
uci set firewall.@rule[-1].src_ip='192.168.99.100'
```

## PoE does not appear

```sh
ls /sys/class/poe/          # expect poe0, port0, port1, sys_ports
lsmod | grep 59111          # expect the bcm59111 module
cat /sys/class/poe/poe0/power_budget
```

If the directory is missing, the module did not load:

```sh
modprobe bcm59111
dmesg | grep -i 59111
```

A common cause is autoload timing. The BCM59111 sits on I2C, and the driver
can only bind once the I2C client is instantiated - around 16 seconds into
boot. If the module is listed in **both** `modules-boot.d` (which loads at about
8 seconds) and `modules.d` (about 17.5 seconds), the early attempt fails
silently and PoE is missing on every boot.

Check:

```sh
ls /etc/modules-boot.d/60-hwmon-bcm59111   # must NOT exist
cat /etc/modules.d/60-hwmon-bcm59111       # should print bcm59111
```

Remove the `modules-boot.d` entry so only the later, correctly-timed load
happens.

## PoE works but shows no power

Ports read `enabled=0` and `status=0` when nothing is connected. That is
normal. Attach a PoE device to `lan11` or `lan12`, then:

```sh
for p in port0 port1; do
  echo "== $p"
  for a in enabled status class power; do
    printf "  %-8s %s\n" "$a" "$(cat /sys/class/poe/$p/$a)"
  done
done
```

A working port shows `status 4` (good) with a non-zero `class` and `power`.

## WAN does not get a DHCP lease

**Symptom:** No address on the WAN interface, or a lease that does not survive
a reboot.

**Cause:** the WAN interface bound to a bridge *port* instead of the bridge.
On the MX65, `wan1` and `wan2` are members of `br-wan`. The logical interface
must be bound to the bridge:

```sh
uci get network.wan.device      # must be br-wan, not wan1
```

If it reads `wan1`, fix it:

```sh
uci set network.wan.device='br-wan'
uci commit network
/etc/init.d/network restart
```

Binding DHCP to a bridge slave port is unreliable. netifd sometimes tolerates
it, but a reboot can lose the lease.

Check the link too, and the reason from the interface state:

```sh
ip addr show br-wan
logread | grep -i udhcpc
```

## `apk` refuses to install anything

**Symptom:**

```
ERROR: unable to select packages:
    conflicts: libubus20260925-...[libubus=2025.11.03~0d4bcb56-r1]
```

**Cause:** your firmware is a snapshot build, and the snapshot feeds have moved
on. Snapshot packages only match the exact snapshot they were built against.

**Fix:** use a firmware built from the current snapshot. Do **not** force the
mismatch - swapping `libubus`, `netifd` and `rpcd` under a running system can
break the install.

To confirm your firmware matches the feed:

```sh
cat /etc/openwrt_release | grep REVISION   # e.g. r0-7670f36
```

## A service still listens on the old LAN address

After changing the LAN subnet, a service bound at boot time to the previous
address may keep the stale value:

```sh
netstat -tlnp | grep 192.168.1.1     # old subnet
```

Restart the affected service so it rebinds:

```sh
/etc/init.d/ttyd restart
```

## Device rebooted but no LAN connectivity

Give it several minutes. Shmoo switch calibration runs on cold boot and the
first boot of a new image is usually slower than steady state. The LED pattern
is solid orange during this phase, then green flashing fast, then slow, then
solid.

If it never reaches solid green, power-cycle once - a cold cycle often resolves
a stalled calibration.

## Recovery after a failed flash

1. Leave the USB stick plugged in.
2. Power on. U-Boot falls back to the USB initramfs when the NAND boot is
   invalid.
3. You get an SSH shell on `192.168.1.1`.
4. Re-flash a known-good image:

```sh
scp -O openwrt-bcm53xx-generic-meraki_mx65-squashfs.sysupgrade.bin root@192.168.1.1:/tmp/
ssh root@192.168.1.1
sha256sum /tmp/openwrt-bcm53xx-generic-meraki_mx65-squashfs.sysupgrade.bin
sysupgrade /tmp/openwrt-bcm53xx-generic-meraki_mx65-squashfs.sysupgrade.bin
```

Verify the checksum **before** flashing. `/tmp` is RAM, so a truncated transfer
survives long enough to fail after the flash has started.

## Collecting diagnostics for a bug report

```sh
cat /etc/openwrt_release
uname -r
cat /proc/mtd
ubinfo -a
ip -br addr
ip route
uci show network
uci show firewall
ls /sys/class/poe/
lsmod
logread | tail -50
```

`fw_printenv` output is also useful if the bootloader seems involved.