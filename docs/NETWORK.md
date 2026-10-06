# Network configuration

A worked example: the MX65 acting as the main router for a `192.168.88.0/24`
LAN, uplinked through an existing `192.168.99.0/24` network.

## Topology

```
   upstream router 192.168.99.3
            |
   MX65W  wan1  (DHCP, gets 192.168.99.125)
            |
   MX65W  br-lan  192.168.88.1/24  (DHCP 192.168.88.100-249)
     |     |     |     |     |
   lan3 lan4  lan5 lan6  lan7      ... lan8-lan10
                            |
                      lan11 / lan12   (PoE+)
```

`lan3`-`lan12` are in the `lan` zone and bridged. `wan1` and `wan2` are in the
`wan` zone.

Note that traffic between `lan3`-`lan7` and `lan8`-`lan12` is switched inside
the Broadcom switch and never reaches the CPU, so bridging the two switch
groups costs nothing.

## Why LAN and WAN need different subnets

Two routers on the same subnet cannot work. The upstream router at
`192.168.99.3` and the MX65W's WAN at `192.168.99.125` are on `192.168.99.0/24`;
if the MX65W's LAN also used `.99`, you would have two DHCP servers, duplicate
addresses, and no way for either device to tell its own LAN from its uplink.

So the LAN must be a separate range. `192.168.88.0/24` is a good choice because
it stays visually adjacent to `.99` without overlapping.

## Configuration

```sh
# LAN address
uci set network.lan.ipaddr='192.168.88.1'
uci set network.lan.netmask='255.255.255.0'

# DHCP pool: .100 - .249, leaving .2-.99 for static devices
uci set dhcp.lan.start='100'
uci set dhcp.lan.limit='150'
uci set dhcp.lan.leasetime='12h'

# WAN by DHCP from the upstream router.
# The device must be bound to br-wan, NOT to the wan1 bridge port.
uci set network.wan=interface
uci set network.wan.proto='dhcp'
uci set network.wan.device='br-wan'

# LAN zone: accept admin input from LAN, and allow forwarding out to WAN
uci set firewall.@zone[0].input='ACCEPT'
uci set firewall.@zone[0].output='ACCEPT'
uci set firewall.@zone[0].forward='ACCEPT'

# WAN zone: masquerade so LAN clients get outbound connectivity
uci set firewall.@zone[1].masq='1'
uci set firewall.@zone[1].mtu_fix='1'

uci commit network
uci commit dhcp
uci commit firewall
```

Apply with:

```sh
/etc/init.d/network restart
/etc/init.d/firewall restart
/etc/init.d/dnsmasq restart
```

## Verifying

```sh
ip addr show br-lan | grep inet      # 192.168.88.1/24
ip addr show br-wan | grep inet      # 192.168.99.125/24
ip route                            # default via 192.168.99.3 dev br-wan

grep dhcp-range /var/etc/dnsmasq.conf.*
# dhcp-range=set:lan,192.168.88.100,192.168.88.249,255.255.255.0,12h

nft list ruleset | grep masquerade
```

Connect a client to a LAN port; it should get a `192.168.88.x` address and reach
the internet.

## Allowing management access from the upstream network

The `wan` zone is `input REJECT` by default, so nothing is reachable from
`192.168.99.0/24` until you allow it. This is the correct default; open only what
you need, and scope it to the smallest range that works.

```sh
# SSH
uci add firewall rule
uci set firewall.@rule[-1].name='Allow-SSH-from-99'
uci set firewall.@rule[-1].src='wan'
uci set firewall.@rule[-1].src_ip='192.168.99.0/24'
uci set firewall.@rule[-1].proto='tcp'
uci set firewall.@rule[-1].dest_port='22'
uci set firewall.@rule[-1].target='ACCEPT'

# Web interface
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

If you only administer from one workstation, use its address instead of the
whole subnet:

```sh
uci set firewall.@rule[-1].src_ip='192.168.99.100'
```

## Handover checklist for an administrator

The router should be left in a known state. Verify:

- [ ] LAN is `192.168.88.1/24`, WAN has an address via DHCP
- [ ] A client on a LAN port receives `192.168.88.100`-`.249` and reaches the
      internet
- [ ] LuCI loads from both a LAN client and the management network
- [ ] A root password is set (`passwd`) - the shipped image has none
- [ ] The clock is correct (NTP is enabled by default; there is no RTC, so this
      only holds once NTP has synced)
- [ ] `lan11`/`lan12` PoE confirmed with a real device if PoE is required
- [ ] The USB stick removed, or kept in place as a known-good recovery path

Set the password first. A router reachable from the management subnet with no
root password is a real exposure.

## Double NAT

With the MX65W downstream of another router, WAN-bound traffic is NAT'd twice.
Browsing, updates and most services are unaffected. What breaks:

- Inbound port forwarding, unless you forward on both routers
- Some VPNs and peer-to-peer protocols
- Games and VoIP with strict NAT traversal

If you need inbound connectivity, make the MX65W the only router for that
network instead.

## Cleaning up after a subnet change

Services that bind at boot may keep the previous address:

```sh
netstat -tlnp | grep 192.168.1.1
```

Restart whatever is listed:

```sh
/etc/init.d/ttyd restart
```