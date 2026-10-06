# Installing OpenWrt on the Cisco Meraki MX65 / MX65W

The MX65 and MX65W are identical from an installation standpoint. The only
hardware difference is that the MX65W adds two unsupported Broadcom wireless
radios.

## Before you start

You need:

- A USB stick (2 GB or larger). **FAT16, 128 MB partition, DOS/MBR label.**
- An Ethernet cable.
- A client machine that can set a static IP address.

The MX65's factory firmware needs to be replaced with a U-Boot build before
OpenWrt can boot, because the original bootloader cannot start Linux from NAND.

## Step 1 - Prepare the USB stick

Partition it with an MBR (DOS) label and one 128 MB FAT16 partition:

```sh
wipefs -a /dev/sdX
parted -s /dev/sdX mklabel msdos
parted -s -a optimal /dev/sdX mkpart primary fat32 1MiB 129MiB
mkfs.vfat -F 16 -n OPENWRT /dev/sdX1
mount /dev/sdX1 /mnt/dos
```

128 MB is the documented size and keeps the cluster count well inside FAT16
limits. A FAT32 partition also works if a stick refuses to boot.

Copy these files **into the root of the partition** (not a subdirectory):

| File | Where to get it |
|---|---|
| `openwrt-bcm53xx-generic-meraki_mx65-initramfs.bin` | [this project](#building) |
| `openwrt-bcm53xx-generic-meraki_mx65-squashfs.sysupgrade.bin` | [this project](#building) |
| `uboot_mx65` and `uboot_mx65.sha512` | [clayface/U-boot-MX64-20190430_MX65](https://github.com/clayface/U-boot-MX64-20190430_MX65) |
| `uboot_mx65_small` and `uboot_mx65_small.sha512` | same repo |
| `sha512sum` | [DimmaDont/busybox releases](https://github.com/DimmaDont/busybox/releases) |

Two files are needed for U-Boot because the flash layout differs between
hardware revisions; you will only use one of them.

Verify the initramfs filename is byte-exact. U-Boot matches on that literal
string, and a stray space or CRLF makes the device appear to hang.

## Step 2 - Enter diagnostic mode

1. Plug the USB stick into the MX65.
2. Hold **reset** while powering on, for about 15 seconds. The front light goes
   orange, then blinks white twice.
3. Release reset and wait about 15 more seconds. The light should turn green.
   If it turns rainbow instead, unplug and try again.
4. Connect an Ethernet cable to any LAN port.

The white blink is hard to see on used units. If you cannot see it, just hold
reset for about 15 seconds.

## Step 3 - Check the flash layout

From a client set to `192.168.1.2`, telnet to `192.168.1.1`:

```sh
telnet 192.168.1.1
```

```sh
cat /proc/mtd
```

The size of `mtd0` decides which U-Boot image to flash:

- `mtd0` is `00100000` (1 MB) or larger - use `uboot_mx65`
- `mtd0` is `00080000` (512 KB) - use `uboot_mx65_small`

Flashing the 1 MB image over a 512 KB partition would overrun it.

## Step 4 - Flash U-Boot

Confirm the USB stick is visible:

```sh
mount
ls /tmp/media/sda1
```

If nothing is listed, the stick did not mount. Power off, re-enter diagnostic
mode with the stick already inserted, and try again. The device may also mount
it as `sdb1`.

Copy the U-Boot image to RAM and verify it:

```sh
cp /tmp/media/sda1/uboot_mx65 /tmp
chmod +x /tmp/media/sda1/sha512sum
/tmp/media/sda1/sha512sum /tmp/uboot_mx65
cat /tmp/media/sda1/uboot_mx65.sha512
```

The hashes must match exactly.

Then write it:

```sh
dd if=/tmp/uboot_mx65 of=/dev/mtdblock0 bs=256K
```

Wait for the record count, then remove power.

> **This step is not reversible.** Interrupting it can leave the boot partition
> unusable. The stock Meraki bootloader is gone afterwards, and the only
> recovery path is the initramfs on the USB stick.

## Step 5 - Boot the initramfs

Leave the USB stick plugged in and power on **without holding reset**. The new
U-Boot finds the initramfs by itself.

Expected LED sequence:

1. White blinks three times as it enters USB boot
2. Solid orange while the kernel boots
3. Green flashing fast, then slow, then solid

This takes about a minute. The first boot can be much slower while Shmoo switch
calibration runs. If it stalls at orange, power-cycle; a cold cycle often fixes
it.

## Step 6 - Install OpenWrt

SSH in:

```sh
ssh root@192.168.1.1
```

If the initramfs has USB storage support, you can flash straight from the stick.
Otherwise copy the image over the network.

```sh
ls /dev/sd*
```

With USB storage available:

```sh
mkdir -p /mnt/usb && mount /dev/sda1 /mnt/usb
sysupgrade /mnt/usb/openwrt-bcm53xx-generic-meraki_mx65-squashfs.sysupgrade.bin
```

Without it, copy the sysupgrade image from your workstation:

```sh
scp -O openwrt-bcm53xx-generic-meraki_mx65-squashfs.sysupgrade.bin root@192.168.1.1:/tmp/
```

Use `scp -O` for OpenSSH 9+, which defaults to the SFTP protocol. Dropbear often
has no SFTP subsystem.

Verify before flashing, because a truncated transfer fails late and can leave the
device unbootable:

```sh
sha256sum /tmp/openwrt-bcm53xx-generic-meraki_mx65-squashfs.sysupgrade.bin
```

Then flash. Use tab completion for the filename rather than typing it out:

```sh
sysupgrade /tmp/openwrt-bcm53xx-generic-meraki_mx65-squashfs.sysupgrade.bin
```

`Cannot save config while running from ramdisk` is expected here. SSH will drop
as the device reboots. Keep the USB stick plugged in through the reboot so you
still have a recovery path.

## Step 7 - Reclaim flash space

Factory Meraki volumes occupy most of the 1 GB NAND. You can free roughly
600 MB by removing the volumes OpenWrt does not use.

This is **destructive and irreversible** - it destroys the stock Cisco
configuration, so you cannot return the device to factory firmware afterwards.
Do not remove `board-config`; the bootloader uses it and Ethernet will not
initialise without it.

```sh
ubinfo -a
ubirmvol /dev/ubi0 -N storage
ubirmvol /dev/ubi0 -N diagnostic1
ubirmvol /dev/ubi0 -N part.old
ubirmvol /dev/ubi0 -N part.safe
ubinfo -a
```

You should see available eraseblocks rise from about 1489 to about 3975
(962 MiB).

Afterwards, run the sysupgrade again so `rootfs_data` claims the freed space.

## Step 8 - Verify

```sh
cat /etc/openwrt_release
ubinfo -a
mount | grep rom
dmesg | grep -i poe
ls /sys/class/poe/
```

A healthy install shows:

- `/dev/root on /rom type squashfs`
- a `rootfs_data` volume of several hundred MiB
- `poe0`, `port0`, `port1` under `/sys/class/poe`

You can now remove the USB stick.

## Network defaults

OpenWrt ships with:

- LAN `192.168.1.1/24`, DHCP handing out `192.168.1.100`-`192.168.1.249`
- WAN on DHCP, for connection to an upstream router

LAN ports are `lan3`-`lan12`; WAN ports are `wan1` and `wan2`.

If the MX65 sits behind another router, keep the LAN subnet distinct from the
upstream subnet to avoid overlapping routes.

## Troubleshooting

**White LED blinks but nothing boots.** Check the initramfs filename is exact,
and try a different USB stick or FAT32.

**Solid orange, no response.** Shmoo calibration can take several minutes. Wait,
then power-cycle.

**No U-Boot banner on serial.** Some USB serial adapters prevent boot by
asserting DTR/RTS. Connect the adapter's TXD only after the light starts
blinking white.

**`sysupgrade` reports "Image metadata not present".** Benign on `bcm53xx`.

**PoE missing after install.** `ls /sys/class/poe` should show the ports. If it
is empty, the driver did not load - check `dmesg | grep -i 59111`.

## Recovering from a bad flash

If the device will not boot from NAND:

1. Plug the USB stick back in.
2. Hold **reset** while powering on for about 15 seconds.
3. It should boot the initramfs from the stick, giving you an SSH shell.
4. Re-run `sysupgrade` with a known-good image.

This works as long as the stick still contains the initramfs.