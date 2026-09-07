# Project status

**Scope:** a hands-on Linux infrastructure lab. All planned lab objectives are
complete. Nothing below is aspirational — items still outstanding are listed
explicitly in the last section.

Last updated after the repository cleanup and standardisation pass.

## Completed

| Area | State | Where |
|---|---|---|
| Two-node build (web01, app01) with static private IPv4 | Complete | `networking/network-configuration.md`, `evidence/01-network-setup.txt` |
| Connectivity testing (ping, ARP, routing, sockets) | Complete | `evidence/01-network-setup.txt` |
| SSH between nodes, key-based, hardened | Complete | `linux/ssh.md`, `evidence/11-sshd-app01.log` |
| Users, groups, permissions, SGID, sticky bit, ACLs, sudo | Complete | `linux/users-permissions.md`, `evidence/02-users-permissions-firewall.txt` |
| Nginx install and service lifecycle | Complete | `linux/service-management.md`, `evidence/06-service-management.txt` |
| Firewall (default-deny with allow-list), behaviour verified | Complete | `networking/network-configuration.md` |
| Storage: ext4 volume, capacity and inode monitoring, `du`/`df` | Complete | `storage/storage-management.md` |
| RAID1 operational lifecycle simulation + documented `mdadm` procedures | Complete — see scope note below | `storage/raid1-simulation.md`, `runbooks/raid1-runbook.md` |
| CPU / memory / disk monitoring | Complete | `evidence/03-baseline-web01.txt`, `evidence/04-baseline-app01.txt` |
| Bash health check script | Complete | `monitoring/health-check.sh` |
| Python fleet monitor (SSH collection, JSON, CSV history) | Complete | `monitoring/fleet-monitor.py` |
| Five simulated incidents, executed and captured | Complete | `incidents/`, `evidence/inc-0*.txt` |
| Five incident reports, standardised format | Complete | `incidents/` |
| Architecture diagram | Complete | `architecture/` |
| Screenshots (19, rendered from evidence) | Complete | `screenshots/` |
| Runbooks: systemd, RAID1/mdadm, troubleshooting | Complete | `runbooks/` |
| README and documentation | Complete | `README.md` |

## Scope notes — what was simulated rather than implemented

These are stated so the completion table above is not misread.

- **RAID1 was simulated, not implemented.** The lab kernel has no `md` driver,
  verified and captured in `evidence/07-raid1-mirror-drill.txt`. The RAID1
  operational lifecycle (member failure, degraded operation, replacement,
  resynchronisation, validation) was exercised on loop-backed storage; real
  `mdadm` commands are documented for use on a full Linux VM.
- **systemd procedures are documented, not captured.** PID 1 on the lab host is
  not systemd, so `systemctl` and `journalctl` cannot run. Service control used
  equivalent commands, annotated with their systemd counterparts.
- **Nodes are network namespaces, not virtual machines.** Network isolation is
  real; kernel, process table and filesystem are shared.
- **Screenshots are rendered from captured text**, not taken from a GUI, since
  the host is headless.

## Outstanding / not implemented

These were not required for the lab objectives and remain genuinely undone:

- Firewall rule persistence (`iptables-save` / `netfilter-persistent`) and an
  equivalent `ufw` policy. Rules are applied at build time only.
- `/etc/fstab` entries for the loop-backed volumes. The correct UUID-based entry
  is documented in `storage/storage-management.md` and in the build script
  comments, but is not applied.
- Scheduled execution of the health check (cron entry or systemd timer) and
  `logrotate` configuration for the nginx logs.
- Rebuild on full Linux VMs to exercise `systemctl` and `mdadm` directly. Both
  runbooks are written and ready for that.
