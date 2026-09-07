# systemd & journalctl runbook

**Why this is a runbook and not a capture.** The lab host runs `process_api` as
PID 1, not systemd, so the service manager and the journal are offline. The real
proof is in `evidence/05-systemd-check.txt`:

```
$ systemctl is-system-running
offline
$ systemctl status nginx
System has not been booted with systemd as init system (PID 1). Can't operate.
$ journalctl -u nginx -n 5
No journal files were found.
```

Rather than fabricate output, service control in the lab was done with equivalent
commands (`evidence/06-service-management.txt`, each step annotated with its
systemd counterpart). This file is the procedure for a real Ubuntu VM, where
every command below applies unchanged.

---

## Service lifecycle

| Task | Command | Lab equivalent used |
|---|---|---|
| Status + recent logs | `systemctl status nginx` | `pgrep -a nginx`, `ss -tlnp`, `cat /run/nginx.pid` |
| Start | `systemctl start nginx` | `nginx -c <conf>` |
| Stop | `systemctl stop nginx` | `nginx -s quit -c <conf>` (graceful) |
| Restart (drops connections) | `systemctl restart nginx` | stop, then start |
| Reload (no downtime) | `systemctl reload nginx` | `nginx -s reload -c <conf>` |
| Start at boot | `systemctl enable nginx` | n/a — no init in the lab |
| Enable and start now | `systemctl enable --now nginx` | |
| Prevent from starting at all | `systemctl mask nginx` | |
| Is it running / enabled? | `systemctl is-active nginx` / `is-enabled nginx` | `pgrep`, port check |
| List failed units | `systemctl --failed` | |
| Everything nginx-ish | `systemctl list-units 'nginx*'` | |

**Reload vs restart matters operationally.** `reload` sends SIGHUP; nginx starts
new workers with the new config while the old ones finish in-flight requests, and
the listening socket is never released. `restart` releases the socket, which is
exactly the window that let a rogue process seize port 80 in INC-003. Reload
whenever the change permits it.

**Always validate before applying:** `nginx -t` (nginx), `sshd -t` (sshd),
`named-checkconf`, `visudo -c`. A broken config plus `restart` equals an outage;
a broken config plus `-t` equals a no-op.

## Reading the journal

```bash
journalctl -u nginx                  # everything for one unit
journalctl -u nginx -n 50            # last 50 lines
journalctl -u nginx -f               # follow, like tail -f
journalctl -u nginx --since "10 min ago"
journalctl -u nginx --since "2026-09-06 23:00" --until "2026-09-06 23:30"
journalctl -u nginx -p err           # priority err and worse (0 emerg … 7 debug)
journalctl -u nginx -b               # this boot only;  -b -1 = previous boot
journalctl -k                        # kernel ring buffer (dmesg)
journalctl -xe                       # end of the log with explanatory hints
journalctl -u nginx -o json-pretty   # structured, for parsing
journalctl --disk-usage              # how much space the journal is using
journalctl --vacuum-time=7d          # trim it
```

Two options worth internalising: `-p err` cuts noise fast when a unit is flapping,
and `--since` bounded by `--until` is how you extract exactly the incident window
for a report.

## Diagnosing a unit that will not start

```bash
systemctl status nginx -l --no-pager     # state, exit code, last log lines
journalctl -u nginx -n 50 --no-pager     # full context
systemctl cat nginx                      # the effective unit file + drop-ins
systemd-analyze verify nginx.service     # syntax check the unit
systemctl show nginx -p ExecStart -p Restart -p User   # resolved properties
```

Read the **exit code and signal** in `status` first. `status=1/FAILURE` after a
config change is almost always the config; `status=203/EXEC` means the binary
path is wrong; `status=226/NAMESPACE` means a sandbox directive
(`ProtectHome`, `ReadWritePaths`) is blocking a path the service needs.

## Unit file anatomy

```ini
# /etc/systemd/system/server-health.service
[Unit]
Description=Fleet health check
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/health-check.sh -q -p 10.10.10.12
User=sysadmin
StandardOutput=journal

[Install]
WantedBy=multi-user.target
```

Paired timer, the modern replacement for cron:

```ini
# /etc/systemd/system/server-health.timer
[Unit]
Description=Run the fleet health check every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
```

```bash
systemctl daemon-reload                 # required after ANY unit file edit
systemctl enable --now server-health.timer
systemctl list-timers --all
```

**Never edit a packaged unit in `/lib/systemd/system` directly** — it gets
overwritten on upgrade. Use `systemctl edit nginx` to create a drop-in under
`/etc/systemd/system/nginx.service.d/override.conf`.

## Boot and performance

```bash
systemd-analyze                 # total boot time
systemd-analyze blame           # slowest units
systemd-analyze critical-chain  # what actually delayed the boot
systemctl list-dependencies nginx
```

## Applying this to the lab services

On a real VM, the two lab services would be managed as:

```bash
systemctl enable --now nginx
systemctl enable --now ssh          # the unit is 'ssh' on Debian/Ubuntu, 'sshd' on RHEL
systemctl reload ssh                # after editing /etc/ssh/sshd_config, with sshd -t first
```

Note the naming difference: Ubuntu ships the unit as `ssh.service` with an
`sshd.service` alias. Scripts that hardcode `sshd` break on Ubuntu and scripts
that hardcode `ssh` break on RHEL — which is why `health-check.sh` falls back to
a process/port check rather than assuming a unit name.
