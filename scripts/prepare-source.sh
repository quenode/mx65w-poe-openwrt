#!/bin/sh
# Clone OpenWrt and apply the Meraki MX65 PoE patches.
#
# Safe to re-run: it clones into ./openwrt only if that directory is missing.

set -e

# Resolve the repository root (this script lives in scripts/).
HERE=$(cd "$(dirname "$0")/.." && pwd)
OPENWRT="$HERE/openwrt"
TARGET="target/linux/bcm53xx"

if [ ! -d "$OPENWRT" ]; then
	echo "==> Cloning OpenWrt (this takes a few minutes)"
	git clone --depth 1 https://github.com/openwrt/openwrt.git "$OPENWRT"
fi

cd "$OPENWRT"

echo "==> OpenWrt revision:"
git log -1 --format='    %H %cd %s' --date=short

echo "==> Applying PoE support"

# The driver itself, derived from Cisco's GPL firmware release and modernised
# for current kernels. See patches/001-modernisation.patch for the API changes.
mkdir -p "$TARGET/files/drivers/hwmon"
install -m 0644 "$HERE/driver/bcm59111.c" "$TARGET/files/drivers/hwmon/bcm59111.c"

# PSE firmware blob, shipped so the driver can load it via request_firmware.
mkdir -p "$TARGET/base-files/lib/firmware/brcm"
install -m 0644 "$HERE/driver/bcm59111.bin" \
	"$TARGET/base-files/lib/firmware/brcm/bcm59111.bin"

# Device-tree node so the driver binds to the PSE on i2c0 at 0x21.
install -m 0644 "$HERE/patches/802-ARM-dts-NSP-add-BCM59111-to-MX65.patch" \
	"$TARGET/patches-6.18/802-ARM-dts-NSP-add-BCM59111-to-MX65.patch"

# Kernel-side registration (hwmon Makefile + Kconfig).
install -m 0644 "$HERE/patches/801-hwmon-add-BCM59111-PSE-support.patch" \
	"$TARGET/patches-6.18/801-hwmon-add-BCM59111-PSE-support.patch"

# Package wiring: kmod-hwmon-bcm59111 plus automatic install on meraki_mx65.
if ! grep -q KernelPackage/hwmon-bcm59111 "$TARGET/modules.mk"; then
	cat >> "$TARGET/modules.mk" <<'EOF'

define KernelPackage/hwmon-bcm59111
  TITLE:=Broadcom BCM59111 PSE support
  KCONFIG:=CONFIG_SENSORS_BCM59111
  DEPENDS:=@TARGET_bcm53xx +kmod-hwmon-core +kmod-i2c-core
  SUBMENU:=$(HWMON_MENU)
  FILES:=$(LINUX_DIR)/drivers/hwmon/bcm59111.ko
  AUTOLOAD:=$(call AutoLoad,60,bcm59111,1)
endef

define KernelPackage/hwmon-bcm59111/description
  Kernel module for the Broadcom BCM59111 PSE (PoE) controller.
endef

$(eval $(call KernelPackage,hwmon-bcm59111))
EOF
	echo "    added kmod-hwmon-bcm59111 to modules.mk"
fi

# Add the kmod to the device only if it is not already there.
if ! grep -q 'DEVICE_PACKAGES += kmod-hwmon-bcm59111' "$TARGET/image/Makefile"; then
	python3 - "$TARGET/image/Makefile" <<'PY'
import sys
path = sys.argv[1]
with open(path) as fh:
	text = fh.read()
anchor = "  DEVICE_DTS := bcm958625-meraki-mx65\n"
if anchor not in text:
	raise SystemExit("could not find meraki_mx65 device block")
text = text.replace(anchor, anchor + "  DEVICE_PACKAGES += kmod-hwmon-bcm59111\n", 1)
with open(path, "w") as fh:
	fh.write(text)
print("    added kmod to meraki_mx65 DEVICE_PACKAGES")
PY
fi

echo "==> Installing luci-app-poe (PoE web UI)"

# The package is installed into package/ rather than into the luci feed
# checkout on purpose: feeds/luci is a git clone, so anything added inside it
# would show up as a local modification and could be discarded by
# ./scripts/feeds update. Its Makefile includes feeds/luci/luci.mk by
# absolute path instead of the usual relative ../../luci.mk.
#
# Rebuilt each run so edits here are always picked up.
rm -rf package/luci-app-poe
mkdir -p package/luci-app-poe
cp -R "$HERE/luci-app-poe/." package/luci-app-poe/
echo "    installed luci-app-poe into package/luci-app-poe"

echo "==> Verifying"
grep -q "ramdisk" "$TARGET/Makefile" \
	|| echo "    WARNING: 'ramdisk' missing from FEATURES; initramfs will not build"
grep -q CONFIG_PACKAGE_luci=y .config 2>/dev/null \
	|| echo "    note: .config not applied yet (run: cp $HERE/config-meraki_mx65.config openwrt/.config)"
grep -q CONFIG_PACKAGE_luci-app-poe=y "$HERE/config-meraki_mx65.config" \
	|| echo "    WARNING: config does not select luci-app-poe; the PoE page will be missing"

echo "==> Done. Next:"
echo "    cp $HERE/config-meraki_mx65.config $OPENWRT/.config"
echo "    make -C $OPENWRT defconfig"
echo "    make -C $OPENWRT -j\$(nproc)"