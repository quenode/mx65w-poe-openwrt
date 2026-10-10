# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

OpenWrt snapshots are dated rather than semantically versioned. Firmware images
are named after the snapshot revision they were built from (for example
`r0-7670f36`) and that string is what identifies a build here.

## [Unreleased]

Nothing yet.

## [1.1.0] - 2026-10-10

Fixes three driver bugs that made the PoE sysfs interface report wrong values.
Build revision is unchanged from 1.0.0 (`r0-7670f36`); only the driver differs.

### Fixed

Three driver bugs, each of which silently reported a wrong value rather than
failing. Full detail in `docs/POE.md`.

- **`status` no longer duplicates `enabled`.** Both were defined with the same
  register, mask and bit offset, so `status` only ever echoed the enable bit
  and could not report whether a device was attached. It now reads the detect
  field of `POE_STATP` and reports `unknown`/`short`/`cpd_high`/`rsig_low`/
  `good`/`rsig_high`/`open`.
- **`detect_state[]` corrected.** It had six strings for seven `DETECT_*`
  values, so `DETECT_OPEN` read past the end of the array, and index 5 was
  labelled `"open"` when it is `DETECT_RSIG_HIGH`. Wiring up `status` without
  fixing this would have converted a wrong value into an out-of-bounds read.
- **`millijoules` is now cumulative and in real millijoules.** It previously
  reported `power_mw * jiffies_since_last_read` - wrong by a factor of
  `1000/HZ`, and reset on every read, so the figure depended on polling
  frequency rather than consumption. There is no hardware energy register on
  this chip, so a one-second timer accumulates the total instead.
- `luci-app-poe` again reports the detection state and energy total now that
  both are trustworthy. It previously derived attachment from `mode` and
  omitted energy entirely.

Verified on live hardware after `sysupgrade`:

| | before | after |
|---|---|---|
| `port0/status` | `1` | `good` |
| `port0/millijoules` | `34263927712` | climbing from 0, in real mJ |
| `port1/status` | `1` | `open` |

`port1` reading `open` is `DETECT_OPEN` (0x6) - index 6, which was out of
bounds in the old six-element `detect_state[]`. Real hardware now exercises
the corrected array.

Energy accounting was cross-checked over 60 seconds against an independent
trapezoidal integration sampled at the same 1 second resolution the driver
uses: driver 267859 mJ versus 269513 mJ integrated, a ratio of 0.9939.

## [1.0.0] - 2026-10-10

First public release. Built against OpenWrt `r0-7670f36`
(commit `7670f36e38fce4105f96b6fdc07350ea65ac8dca`), kernel 6.18.55.

### Added

- **PoE support for the Meraki MX65 and MX65W.** A driver for the Broadcom
  BCM59111 PSE controller, derived from Cisco's MX64/MX65 GPL firmware release
  and ported to current kernel APIs. Ships as `kmod-hwmon-bcm59111` and
  autoloads at priority 60. Both PoE+ ports (`lan11`, `lan12`) work, rated
  30 W each against a 60 W budget.
- **`luci-app-poe`**, a LuCI page at *Network → PoE Ports* showing controller
  budget, total draw and fault flags, plus a per-port table with a power toggle
  that confirms before cutting power to an attached device. Backed by a ucode
  rpcd object:
  - `ubus call poe status '{}'`
  - `ubus call poe set '{"port":1,"enabled":0}'`
- **`meraki_mx65w` device profile**, enabling the two Broadcom iPROC PCIe
  controllers via the MX65W device tree, with `kmod-brcmfmac` so the on-board
  radios can be enumerated. Diagnostic only — no driver binds to BCM43520.
- **First-boot network defaults**
  (`base-files/etc/uci-defaults/50-mx65-network`), so a fresh image comes up on
  the documented `192.168.88.0/24` LAN without manual `uci` commands. Guarded
  so re-flashing over a working configuration cannot rewrite it.
- **Documentation**: `docs/INSTALL.md`, `docs/NETWORK.md`, `docs/POE.md`,
  `docs/WIFI.md`, `docs/MX65W-PROBE.md`, `docs/TROUBLESHOOTING.md`.
- **Release images** for both profiles, published as GitHub release assets with
  SHA256 checksums.

### Fixed

- PoE now survives a reboot reliably. Port state is re-asserted by the driver
  after PSE firmware upload rather than depending on stale state.
- Sysfs permissions on power-control attributes tightened from `0222`/`0666` to
  `0220`/`0664`. The driver exposes power control, so world-writable
  attributes would have let any local user cut power to attached devices.

### Known issues

These are documented in full in `docs/POE.md` and are **not** fixed in 1.0.0.
Each needs a kernel rebuild and a `sysupgrade` to deploy.

- **The `status` sysfs attribute is a duplicate of `enabled`.** It is defined
  with the same register, mask and bit offset, so it can never report a
  detection state. Detect state is reachable only through the
  `overload`/`underload` attributes. Presence should be inferred from `mode`.
- **`detect_state[]` is dead, undersized and mislabelled.** It has six strings
  for seven `DETECT_*` values, so `DETECT_OPEN` reads past the end of the
  array, and index 5 is labelled `"open"` when it is `DETECT_RSIG_HIGH`. It is
  currently unreferenced, but wiring it up to fix the previous issue without
  fixing this one would introduce an out-of-bounds read.
- **`millijoules` is neither millijoules nor cumulative.** It reports
  `power_mw * jiffies_since_last_read` with the counter reset on every read,
  with no unit conversion. `luci-app-poe` deliberately does not expose it.

### Licensing

- Added the per-file copyright and SPDX header to `driver/bcm59111.c`, and
  `driver/README.md` documenting the provenance and licence of the
  `bcm59111.bin` firmware blob. Both are required by GPL-2.0 when redistributing
  Cisco-derived material, and were missing before this release.

[Unreleased]: https://github.com/quenode/mx65w-poe-openwrt/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/quenode/mx65w-poe-openwrt/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/quenode/mx65w-poe-openwrt/releases/tag/v1.0.0