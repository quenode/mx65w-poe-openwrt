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

# Device profiles.
#
# Two separate jobs, each guarded independently:
#
#   1. add the PoE kmod to the existing meraki_mx65 block
#   2. add the meraki_mx65w block, which does not exist upstream
#
# These must not share one guard. An earlier version tested for
# "DEVICE_PACKAGES += kmod-hwmon-bcm59111" anywhere in the file, so once the
# MX65 block had it, the MX65W block was never created.
python3 - "$TARGET/image/Makefile" <<'PY'
import sys

path = sys.argv[1]

with open(path) as fh:
	text = fh.read()

changed = False

# 1. PoE kmod for the stock MX65 profile.
mx65_dts = "  DEVICE_DTS := bcm958625-meraki-mx65\n"
if mx65_dts not in text:
	raise SystemExit("could not find meraki_mx65 device block")

if "DEVICE_PACKAGES += kmod-hwmon-bcm59111" not in text:
	text = text.replace(
		mx65_dts,
		mx65_dts + "  DEVICE_PACKAGES += kmod-hwmon-bcm59111\n", 1)
	changed = True
	print("    added PoE kmod to meraki_mx65 DEVICE_PACKAGES")

# 2. MX65W profile. Upstream has no Device/ entry for it, so a fresh clone
#    cannot build an MX65W image at all without this.
#
#    The mx65w device tree comes from U-Boot's upstream DTS bundle and
#    already exists in the tree; only the profile is missing. It differs from
#    MX65 in enabling pcie0 and pcie1, which is what lets the BCM43520 radios
#    be enumerated. No driver binds to those chips, so kmod-brcmfmac is
#    included only to have the bus probed and reported.
if "Device/meraki_mx65w" not in text:
	anchor = "TARGET_DEVICES += meraki_mx65\n"
	if anchor not in text:
		raise SystemExit("could not find TARGET_DEVICES += meraki_mx65")

	block = anchor + """
# MX65W: the MX65 board plus two BCM43520 wireless chipsets on the Broadcom
# iPROC PCIe controllers. The mx65w device tree enables pcie0 and pcie1,
# which the plain MX65 leaves disabled. Included so the radio hardware can be
# enumerated for diagnosis; no wireless driver binds to BCM43520.
define Device/meraki_mx65w
  $(call Device/meraki_mx6x)
  DEVICE_MODEL := MX65W
  DEVICE_DTS_CONFIG := config@3
  DEVICE_DTS := bcm958625-meraki-mx65w
  DEVICE_PACKAGES += kmod-hwmon-bcm59111
  DEVICE_PACKAGES += kmod-brcmfmac
endef
TARGET_DEVICES += meraki_mx65w
"""

	text = text.replace(anchor, block, 1)
	changed = True
	print("    added Device/meraki_mx65w profile")

if changed:
	with open(path, "w") as fh:
		fh.write(text)
PY

# First-boot network defaults, so a fresh image comes up on the documented
# 192.168.88.0/24 LAN without manual uci commands. The script is guarded and
# no-ops on an already-configured install.
mkdir -p "$TARGET/base-files/etc/uci-defaults"
install -m 0755 "$HERE/base-files/etc/uci-defaults/50-mx65-network" \
	"$TARGET/base-files/etc/uci-defaults/50-mx65-network"
echo "    installed first-boot network defaults"

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

# Every config must select these, otherwise the image ships without them.
# Checked per config because the MX65W probe config drifted once already.
check_config() {
	cfg="$1"
	label="$2"

	[ -f "$cfg" ] || {
		echo "    WARNING: $label config missing ($cfg)"
		return
	}

	for sym in CONFIG_PACKAGE_luci=y \
	           CONFIG_PACKAGE_luci-app-poe=y \
	           CONFIG_PACKAGE_ttyd=y \
	           CONFIG_PACKAGE_luci-app-ttyd=y \
	           CONFIG_PACKAGE_kmod-hwmon-bcm59111=y; do
		grep -q "^$sym" "$cfg" \
			|| echo "    WARNING: $label config does not select $sym"
	done
}

check_config "$HERE/config-meraki_mx65.config" "mx65"
check_config "$HERE/config-meraki_mx65w-probe.config" "mx65w-probe"

# The probe profile additionally needs the wireless stack.
if [ -f "$HERE/config-meraki_mx65w-probe.config" ]; then
	for sym in CONFIG_PACKAGE_kmod-brcmfmac=y CONFIG_PACKAGE_kmod-cfg80211=y; do
		grep -q "^$sym" "$HERE/config-meraki_mx65w-probe.config" \
			|| echo "    WARNING: mx65w-probe config does not select $sym"
	done
fi

# Confirm the MX65W profile really landed, rather than trusting the guard.
grep -q "Device/meraki_mx65w" "$TARGET/image/Makefile" \
	|| echo "    WARNING: meraki_mx65w profile not present in image/Makefile"

grep -q CONFIG_PACKAGE_luci=y .config 2>/dev/null \
	|| echo "    note: .config not applied yet (run: cp $HERE/config-meraki_mx65.config openwrt/.config)"

echo "==> Done. Build either profile with:"
echo "    # production MX65 (WiFi probes will find nothing)"
echo "    cp $HERE/config-meraki_mx65.config $OPENWRT/.config"
echo "    make -C $OPENWRT defconfig && make -C $OPENWRT -j\$(nproc)"
echo
echo "    # MX65W diagnostic (enables PCIe so the radios can be enumerated)"
echo "    cp $HERE/config-meraki_mx65w-probe.config $OPENWRT/.config"
echo "    make -C $OPENWRT defconfig && make -C $OPENWRT -j\$(nproc)"