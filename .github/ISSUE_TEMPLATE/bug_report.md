---
name: Bug report
about: Something does not work as documented
title: ''
labels: bug
assignees: ''
---

<!--
Please read docs/TROUBLESHOOTING.md first - it covers the common failure modes.

DO NOT paste /etc/shadow, SSH host keys, or a router backup archive. A
backup-*.tar.gz contains the dropbear SSH host private keys. Redact MAC
addresses you do not own. Paste the relevant part of dmesg, not everything.
-->

## What happened

<!-- What you did, and what you expected instead. -->

## What actually happened

<!-- Include the exact error or output. -->

## Versions

```
Paste the output of:

  cat /etc/openwrt_release
  cat /tmp/sysinfo/board_name
  uname -a
```

## PoE state

<!--
Paste the output of:

for p in /sys/class/poe/port*; do
  echo "== $p"
  for a in enabled status class mode power overload underload denied; do
    printf '  %-11s %s\n' "$a" "$(cat $p/$a)"
  done
done
for a in power_budget failed_fet failed_temp uvlo_main uvlo_vcc; do
  printf '  %-14s %s\n' "$a" "$(cat /sys/class/poe/poe0/$a)"
done
-->

## Hardware

- Model: <!-- MX65 or MX65W -->
- PoE device attached, if any: <!-- and what it draws -->
- Port used: <!-- lan11 or lan12 -->

## Anything else

<!-- Logs, photos, whatever helps. -->