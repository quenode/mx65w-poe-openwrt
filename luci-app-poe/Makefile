include $(TOPDIR)/rules.mk

LUCI_TITLE:=PoE Port Control (BCM59111)
LUCI_DEPENDS:=+luci-base +rpcd +ucode-mod-fs
LUCI_PKGARCH:=all

PKG_LICENSE:=GPL-2.0-only
PKG_VERSION:=1.0
PKG_RELEASE:=1
PKG_MAINTAINER:=mx65w-poe-openwrt

# This package lives outside the luci feed checkout, so that
# ./scripts/feeds update cannot remove it. Point at luci.mk explicitly.
include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature