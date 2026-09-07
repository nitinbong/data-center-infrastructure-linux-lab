# Network configuration

Evidence: `evidence/01-network-setup.txt`
Screenshots: `screenshots/01-network-connectivity.png`, `screenshots/02-ssh-validation.png`

## Addressing

| Node | Interface | Address | Subnet |
|---|---|---|---|
| web01 | `veth-web` | `10.10.10.11/24` | `10.10.10.0/24` |
| app01 | `veth-app` | `10.10.10.12/24` | `10.10.10.0/24` |

Addresses are static. There is no DHCP and no gateway; the two nodes communicate
directly over the veth link.

## Build

```bash
ip netns add web01
ip netns add app01

ip link add veth-web type veth peer name veth-app
ip link set veth-web netns web01
ip link set veth-app netns app01

ip netns exec web01 ip addr add 10.10.10.11/24 dev veth-web
ip netns exec app01 ip addr add 10.10.10.12/24 dev veth-app
ip netns exec web01 ip link set veth-web up
ip netns exec app01 ip link set veth-app up
ip netns exec web01 ip link set lo up
ip netns exec app01 ip link set lo up
```

The full build is in `scripts/lab-build.sh`.

## Validation performed

| Check | Command | Result |
|---|---|---|
| Addressing | `ip -brief addr show` | both nodes hold the expected address |
| Routing | `ip route show`, `ip route get 10.10.10.12` | connected route via the veth interface |
| Reachability | `ping -c 4 10.10.10.12` | 0% packet loss, sub-millisecond RTT, both directions |
| Layer 2 | `ip neigh show` | peer resolves to `REACHABLE` |
| Listeners | `ss -tlnp` | `:22` and `:80` on web01, `:22` and `:8080` on app01 |
| Application | `curl http://10.10.10.12:8080/health` | `OK app01` |
| Remote access | `ssh 10.10.10.12` from web01 | key-based login succeeds |

## Firewall (app01)

Default-deny inbound with an explicit allow-list. Evidence and packet counters
are in `evidence/02-users-permissions-firewall.txt`.

```bash
iptables -P INPUT DROP
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -p icmp --icmp-type echo-request -m limit --limit 5/sec -j ACCEPT
iptables -A INPUT -p tcp -s 10.10.10.11 --dport 22 -m conntrack --ctstate NEW -j ACCEPT
iptables -A INPUT -p tcp --dport 8080 -j ACCEPT
iptables -A INPUT -j LOG --log-prefix "FW-DROP-IN: " --log-level 4
```

Behaviour was tested rather than assumed: allowed traffic (ICMP, SSH from
10.10.10.11, HTTP 8080) passes, and a request to an unlisted port times out
rather than being refused, confirming the packet is dropped rather than rejected.

Rules are applied at build time and are **not** persisted across reboots.
Persisting them (`iptables-save` / `netfilter-persistent`, or an equivalent `ufw`
policy) is listed as remaining work in `PROJECT-STATUS.md`.
