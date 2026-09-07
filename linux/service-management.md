# Service management

Evidence: `evidence/06-service-management.txt`, `evidence/05-systemd-check.txt`
Screenshot: `screenshots/06-nginx-service.png`

## nginx deployment

Each node runs its own nginx instance bound to its own address:

| Node | Listener | Document root | Health endpoint |
|---|---|---|---|
| web01 | `10.10.10.11:80` | `/srv/webcontent` | `/health` returns `OK web01` |
| app01 | `10.10.10.12:8080` | `/srv/appcontent` | `/health` returns `OK app01` |

Configurations are in `configs/`.

## Lifecycle exercised

| Task | Command used in the lab | systemd equivalent |
|---|---|---|
| Status | `pgrep -a nginx`, `ss -tlnp`, PID file | `systemctl status nginx` |
| Validate config | `nginx -t -c <conf>` | `nginx -t` before `systemctl reload` |
| Reload | `nginx -s reload -c <conf>` | `systemctl reload nginx` |
| Stop | `nginx -s quit -c <conf>` | `systemctl stop nginx` |
| Start | `nginx -c <conf>` | `systemctl start nginx` |
| Logs | access and error logs | `journalctl -u nginx` |

Reload was verified to be non-disruptive: worker PIDs changed while the listening
socket was never released and requests continued to return HTTP 200. Stop was
verified to release the socket, after which `curl` returned connection refused.

## Why systemd commands are documented rather than captured

PID 1 on the lab host is not systemd, so the service manager and journal are
offline. The real output is captured in `evidence/05-systemd-check.txt`:

```
$ systemctl is-system-running
offline
$ systemctl status nginx
System has not been booted with systemd as init system (PID 1). Can't operate.
```

Rather than present fabricated `systemctl` output, service control was performed
with the equivalent commands above and the full systemd procedure — unit files,
timers, `journalctl` filtering, diagnosing a unit that will not start — is
documented in `runbooks/systemd-runbook.md`.

## Operational lessons

- Validate before restarting. A broken config also breaks `nginx -s reload` and
  `nginx -s quit`, because both parse the config to locate the PID file.
- Prefer reload over restart: restart releases the listening socket, which is the
  window that allowed another process to seize port 80 in INC-003.
