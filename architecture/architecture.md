# Architecture

![Architecture diagram](architecture-diagram.png)

## Overview

This is a hands-on lab, not a production environment. It models a two-node Linux
infrastructure using **isolated network namespaces and virtual Ethernet (veth)
interfaces** on a single Ubuntu 24.04 host. Each node has a separate IP stack,
routing table, ARP state, firewall ruleset and set of listening services.

The nodes are referred to throughout as **web01** and **app01**. They are logical
nodes, not separate physical servers and not independent virtual machines.

## Nodes

| | web01 | app01 |
|---|---|---|
| Role | web front-end, monitoring node | application back-end |
| Address | `10.10.10.11/24` (static) | `10.10.10.12/24` (static) |
| Interface | `veth-web` | `veth-app` |
| Web service | nginx on `:80`, doc root `/srv/webcontent` | nginx on `:8080`, doc root `/srv/appcontent` |
| SSH | sshd on `:22` | sshd on `:22`, key-based access from web01 |
| Storage | ext4 on a loop device mounted at `/srv/data`; mirror pair plus hot spare | — |
| Firewall | — | iptables `INPUT` policy `DROP` with an explicit allow-list |

## Link

A veth pair connects the two namespaces on the private subnet `10.10.10.0/24`.
Traffic between the nodes — ICMP, HTTP and SSH — traverses this link and is
subject to app01's firewall rules.

## What is and is not isolated

Network namespaces isolate the network stack. They do **not** isolate the kernel,
the process table or the filesystem, which the two nodes share.

One consequence is documented rather than hidden: a service check based on
`pgrep` matched the other node's nginx process and reported healthy during a real
outage (INC-003). The health check was corrected to test TCP listeners and HTTP
endpoints instead. See `incidents/INC-003-nginx-outage.md`.

## Environment constraints

| Constraint | Effect | Approach taken |
|---|---|---|
| PID 1 is not systemd | `systemctl` and `journalctl` cannot operate | Real error captured in `evidence/05-systemd-check.txt`; service control performed with equivalent commands, each annotated with its systemd counterpart; procedures documented in `runbooks/systemd-runbook.md` |
| Kernel has no `md` driver | `mdadm` RAID1 arrays cannot be created | Verified and captured (`evidence/07-raid1-mirror-drill.txt`); the RAID1 operational lifecycle is simulated on loop-backed devices and real `mdadm` procedures are documented in `runbooks/raid1-runbook.md` |
| Headless host | No GUI screenshots | Terminal images rendered from the captured output by `scripts/make-screenshots.py`; each names its source evidence file |
