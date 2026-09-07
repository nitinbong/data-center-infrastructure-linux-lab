# INC-001 — app01 unreachable from web01

| Field | Value |
|---|---|
| **Incident ID** | INC-001 |
| **Affected node** | app01 (10.10.10.12) |
| **Severity / priority** | High — back-end unreachable; front-end still serving static content |
| **Detected by** | `health-check.sh` peer reachability check on web01 |
| **Duration** | ~4 minutes, detection to verified restoration |
| **Evidence** | `evidence/inc-01-network.txt`, `screenshots/INC-001-triage.png` |
| **Reproduce** | `sudo bash scripts/incident-01-network.sh` |

## Issue

During a change window, app01's interface was reconfigured onto the wrong subnet
(`10.10.20.12/24` instead of `10.10.10.12/24`). All services on app01 continued
running, but nothing on `10.10.10.0/24` could reach the node.

## Symptoms

```
$ ping -c 3 -W 2 10.10.10.12
3 packets transmitted, 0 received, 100% packet loss

$ curl -s -m 4 -o /dev/null -w 'http_code=%{http_code}\n' http://10.10.10.12:8080/health
http_code=000
curl exit=28                      # timeout, not connection refused

$ ssh -o ConnectTimeout=4 10.10.10.12 hostname
ssh: connect to host 10.10.10.12 port 22: Connection timed out
```

Automated collection of app01 by `fleet-monitor.py` also stopped.

**Timeout, not refused** — packets reached nothing at all. A refused connection
would have meant the host answered but no service was listening. That distinction
pointed at the network layer rather than at nginx or sshd.

## Investigation

Triage worked up the stack one layer at a time rather than jumping to the
firewall.

1. **Link** — `veth-web` was `UP` and `LOWER_UP`, with packets transmitting and
   zero errors or drops, so layer 1/2 was healthy locally.
2. **Local address** — web01 still held `10.10.10.11/24` correctly.
3. **Routing** — a connected route to the destination existed via `veth-web`.
4. **Layer 2 resolution** — after flushing the stale cache, the neighbour entry
   for `10.10.10.12` resolved to `INCOMPLETE`. This is the key finding: ARP going
   unanswered is positive evidence that **no host on the segment owns that
   address**, which also rules out a firewall drop, since a host that answers ARP
   would still populate the table.
5. **Peer side** — app01 was confirmed to hold `10.10.20.12/24`.
6. **Services** — `ss -tlnp` on app01 showed both listeners still bound, so the
   services were never the fault.

Flushing the neighbour cache before re-testing mattered: it still held a
`REACHABLE` entry from before the change, which would have been misleading.

## Commands / checks used

```bash
ip -brief link show veth-web              # link state
ip -s link show veth-web                  # error and drop counters
ip -brief addr show                       # local addressing
ip route show ; ip route get 10.10.10.12  # routing
ip neigh flush all ; ping -c1 10.10.10.12 ; ip neigh show   # ARP state
ip netns exec app01 ip -brief addr show   # peer addressing
ip netns exec app01 ss -tlnp              # peer listeners
```

## Root cause

app01's interface was configured with `10.10.20.12/24`. web01 sits on
`10.10.10.0/24` and has no route to `10.10.20.0/24`, and nothing on the shared
layer-2 segment answered for `10.10.10.12`. The kernel on app01 kept its sockets
bound to the now-absent address, which is why local socket state still looked
healthy from the server's own point of view.

## Resolution

```bash
ip netns exec app01 ip addr del 10.10.20.12/24 dev veth-app
ip netns exec app01 ip addr add 10.10.10.12/24 dev veth-app
ip netns exec web01 ip neigh flush all       # clear the failed entry
```

## Validation

```
$ ping -c 3 -W 2 10.10.10.12
3 packets transmitted, 3 received, 0% packet loss
rtt min/avg/max/mdev = 0.046/0.086/0.164/0.055 ms

$ ip neigh show
10.10.10.12 dev veth-web lladdr 6e:c3:e6:10:b8:09 REACHABLE

$ curl -s http://10.10.10.12:8080/health
OK app01

$ ssh 10.10.10.12 'echo SSH restored'
SSH restored
```

## Preventive action

1. Declare static addressing in configuration (`/etc/netplan/*.yaml` on a full
   VM) rather than applying it live, so the running state cannot drift from the
   documented state.
2. Add a post-change verification step: ping the peer and curl the health
   endpoint before closing the change window.
3. Schedule `health-check.sh -p <peer>`, which already exits 2 on peer
   unreachability, so detection is automatic.
4. Maintain an IP allocation table so an out-of-range address is visibly wrong.
