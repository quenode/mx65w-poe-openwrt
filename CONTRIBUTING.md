# Contributing

Thanks for considering a contribution.

This project adds hardware support to OpenWrt for a device OpenWrt does not
otherwise support, so contributions tend to be either **hardware findings** or
**driver fixes**. Both are welcome.

## Before you start

OpenWrt upstream does not have a driver for the Broadcom BCM59111 PoE
controller. The one here is derived from Cisco's GPL firmware release and is
not upstream, so it gets no external review. That makes accurate reporting
especially valuable — including reports of things that do not work.

## Reporting a bug

Please read `docs/TROUBLESHOOTING.md` first; it covers the common failure modes,
including a blank LuCI page caused by a stale `uhttpd.main.lua_prefix`.

When opening an issue, include the output of:

```sh
cat /tmp/sysinfo/board_name
cat /etc/openwrt_release
uname -a

# PoE controller state
for p in /sys/class/poe/port*; do
  echo "== $p"
  for a in enabled status class mode power overload underload denied; do
    printf '  %-11s %s\n' "$a" "$(cat $p/$a)"
  done
done
for a in power_budget failed_fet failed_temp uvlo_main uvlo_vcc; do
  printf '  %-14s %s\n' "$a" "$(cat /sys/class/poe/poe0/$a)"
done

# network
ip -br addr
ip route
logread | tail -100
```

**Never paste `/etc/shadow`, SSH host keys, or a full router backup.** That
includes `backup-*.tar.gz` archives — they contain the dropbear host private
keys. If you attach one by mistake, rotate the keys.

If you are reporting a crash or a driver fault, include the relevant portion of
`dmesg`, not the whole log.

## Pull requests

1. **Open an issue first** for anything larger than a typo. It is easier to
   agree on an approach than to rebase a finished patch.
2. **One logical change per pull request.** A driver fix and a docs update in
   the same commit make review harder and obscure the fix.
3. **Explain the why.** Commit messages should describe the problem and the
   reasoning, not restate the diff. The existing history has commit bodies
   that document *why* a change was made; please match that.
4. **Say what you tested and on what hardware.** "Verified on an MX65W with a
   Grandstream GWN7610 on `lan11`, 3.08 W at class 4" is useful. "Tested" is not.

## Building and testing

```sh
./scripts/prepare-source.sh

cp config-meraki_mx65.config openwrt/.config      # production
# or
cp config-meraki_mx65w-probe.config openwrt/.config   # Wi-Fi probe

make -C openwrt defconfig
make -C openwrt -j"$(nproc)"
```

`prepare-source.sh` is idempotent — re-run it after any change to `driver/`,
`patches/`, `base-files/` or `luci-app-poe/`.

### Before you claim a change works

Please actually run it on hardware where you can. In particular:

```sh
# is the driver loaded?
lsmod | grep bcm59111

# does the PSE see the ports?
ls /sys/class/poe/

# does it agree with reality?
ubus call poe status '{}'

# PoE actually delivers power only if a real device draws it
```

The `Power draw` figure in `ubus call poe status` is the meaningful test. A
port reporting healthy with nothing attached proves very little.

## Coding style

Match the surrounding code. The driver is kernel C — follow the Linux kernel
style already used in it. Shell scripts are POSIX `sh` with tabs. The LuCI app
is ucode and client-side JavaScript, following `luci-app-sfp-info` as a model.

## Licensing of contributions

By opening a pull request you agree that your contribution is licensed under the
GPL-2.0, the same terms as the rest of this repository.

If your contribution is derived from Cisco firmware or any other third-party
source, say so explicitly in the pull request and make sure the provenance and
licence are recorded in the files you add — a top-level `LICENSE` is not
sufficient for GPL-2.0.

## Licence

GPL-2.0-only. See [`LICENSE`](LICENSE). Portions are derived from Cisco's MX64/MX65
GPL firmware release; see the attribution section of `LICENSE` and
`driver/README.md`.