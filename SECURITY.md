# Security Policy

## Supported versions

This project tracks OpenWrt snapshots rather than maintaining its own release
branches. There is currently one release line.

| Version | Supported |
|---------|-----------|
| 1.0.x | yes |
| OpenWrt snapshots older than the current one | no |

Fixes are made on `master` and released as a new tag. If you are on an older
image, rebuild from the current `master` rather than waiting for a backport.

## Reporting a vulnerability

**Do not open a public issue for a security problem.**

Report it privately via GitHub's security advisory form for this repository
(*Security → Report a vulnerability*), or by email to the maintainer.

Please include:

- the affected file or component
- the firmware version (`cat /etc/openwrt_release`)
- how it can be exploited, and what an attacker gains
- reproduction steps

You should get an acknowledgement within a week. Fixes land on `master`, and a
release is tagged once they are published.

## What counts as a security issue here

This is router firmware that exposes a web interface and a root shell, so the
usual things apply:

- **Remote code execution** without authentication, via uhttpd, LuCI, or a
  listening service such as `ttyd`
- **Authentication bypass** on the web interface or SSH
- **Privilege escalation** from an unprivileged local user to root
- **Command injection** through a LuCI form or RPC method
- **Unauthenticated exposure of credentials**, for example leaking
  `/etc/shadow` or SSH keys through a web endpoint
- **PoE power control reachable without authorisation.** Cutting power to an
  attached device is a denial-of-service against whatever that device is
  doing.

## Things that are *not* vulnerabilities

Please report these as ordinary bugs instead:

- **The default root password.** Fresh OpenWrt installs have none set, and we do
  not ship one. Choosing a weak password is a configuration problem.
- **`ttyd` and LuCI being reachable from a network you control.** Both are
  opt-in and both bind to the LAN by default. Widening that is a firewall
  decision.
- **Raw PoE register access** at `/sys/class/poe/poe0/reg` and `reg_arg`. These
  require root and are provided by the driver as a debugging aid. They are not
  reachable from LuCI and are not treated as a vulnerability.
- **Failure to bind to a network you expected.** The default is LAN-only.
- **Physical access.** Opening the case is out of scope.

## Hardening notes

The PoE driver exposes power control through sysfs, so it deliberately uses
tight permissions (`0220`/`0664`) rather than the `0222`/`0666` found in
Cisco's original. Those wider modes would let any local user cut power to your
attached devices. Changes that relax them should be treated as a security
regression.

The `set` method on the `poe` ubus object performs power control and is gated
behind a write ACL in `luci-app-poe/root/usr/share/rpcd/acl.d/`. If you can
make it callable from a read-only session, that is a vulnerability.