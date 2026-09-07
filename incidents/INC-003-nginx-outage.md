# INC-003 — nginx will not start on web01 after a configuration change

| Field | Value |
|---|---|
| **Incident ID** | INC-003 |
| **Affected node** | web01 (10.10.10.11) |
| **Severity / priority** | Critical — total loss of front-end HTTP service |
| **Detected by** | `health-check.sh` HTTP endpoint check returning CRITICAL |
| **Duration** | ~6 minutes across three separate faults |
| **Evidence** | `evidence/inc-03-service.txt`, `screenshots/INC-003-triage.png`, `screenshots/INC-003-resolution.png` |
| **Reproduce** | `sudo bash scripts/incident-03-service.sh` |

## Issue

A routine configuration change became a full outage through three stacked faults:
a typo that prevented nginx from starting, a stale helper process that took
TCP/80 while nginx was stopped, and a document root that had never been created.
Each fault masked the next, so service returned in three stages.

## Symptoms

```
$ curl -s -m 4 -o /dev/null -w 'HTTP %{http_code}\n' http://10.10.10.11/
HTTP 000
curl exit=28

$ pgrep -a nginx | grep web01
(no nginx master for web01 - service is stopped)
```

Health check during the outage:

```
  CRIT  http:http://10.10.10.11/        no HTTP response (connect failed or timed out)
  CRIT  http:http://10.10.10.11/health  no HTTP response (connect failed or timed out)
 OVERALL: CRITICAL - 2 issue(s)
```

> **A defect this incident exposed in the lab's own tooling.** The first version
> of `health-check.sh` tested services with `pgrep -x nginx` and reported **OK
> during this outage**, because the two nodes share a PID namespace and `pgrep`
> matched app01's nginx. A process-name check is a weak proxy for "the service
> works". The script was corrected to check TCP listeners (`-l`) and HTTP
> endpoints (`-u`); the re-run correctly reported CRITICAL. Both the false OK and
> the corrected CRITICAL are preserved in the evidence file.

## Investigation

**Fault 1 — configuration.** Attempting to start produced
`[emerg] unknown directive "worker_conections" ... :5`. `nginx -t` reported the
same file and line. This is the equivalent of `systemctl status` plus
`journalctl -u nginx` on a systemd host.

**Fault 2 — port conflict.** With the typo fixed, the start failed with
`bind() to 10.10.10.11:80 failed (98: Address already in use)`. `ss -tlnp` named
the process holding the socket. It was identified via `ps` and
`/proc/<pid>/exe` **before** being terminated — killing an unidentified process
on a live host risks turning a service outage into a data incident.

**Fault 3 — wrong document root.** nginx then started but returned HTTP 404. A
404 with a healthy listener is a content or configuration problem, not a service
problem. The `root` directive pointed at `/srv/webcontent-v2`, which did not
exist.

## Commands / checks used

```bash
nginx -c <conf>                       # attempt start, read the error
nginx -t -c <conf>                    # validate configuration
ss -tlnp sport = :80                  # identify the socket owner
ps -o pid,ppid,user,etime,cmd -p <pid>
ls -l /proc/<pid>/cwd /proc/<pid>/exe # confirm what the process actually is
tail <error log>
ls -ld /srv/webcontent-v2             # confirm the missing document root
curl -s -o /dev/null -w '%{http_code}' http://10.10.10.11/
```

## Root cause

A single unreviewed configuration edit introduced two errors: a misspelled
`worker_connections` directive and a `root` pointing at a non-existent path. The
outage was extended by an unrelated stale process that was able to claim port 80
during the window in which nginx was stopped.

## Resolution

```bash
sed -i 's/worker_conections/worker_connections/' nginx.conf     # fault 1
kill <pid>                                                       # fault 2
sed -i 's#root  /srv/webcontent-v2;#root  /srv/webcontent;#' nginx.conf   # fault 3
nginx -t -c nginx.conf && nginx -c nginx.conf
nginx -s reload -c nginx.conf
```

## Validation

```
$ curl -s -o /dev/null -w 'HTTP %{http_code} in %{time_total}s\n' http://10.10.10.11/
HTTP 200 in 0.000443s

$ curl -s http://10.10.10.11/health
OK web01

$ ss -tlnp sport = :80
LISTEN 0 511 10.10.10.11:80 users:(("nginx",pid=5156),("nginx",pid=5132))
```

Health check re-run: `OVERALL: OK - all checks passed`.

## Preventive action

1. Validate before restarting. `nginx -t` would have caught fault 1 before the
   service was ever stopped, turning an outage into a no-op.
2. Prefer `reload` over stop/start. Reload replaces workers without releasing the
   listening socket, which would have made fault 2 impossible.
3. Monitor endpoints, not processes. This incident is the direct reason the
   health check performs HTTP checks: a listening socket is not proof of a
   working service, and a running process is not proof of a listening socket.
4. Version configurations and review the diff. A backup was taken but the change
   itself was not reviewed; both errors would be visible in a diff.
5. Audit what starts from cron — the stale helper should not have been able to
   bind that port.
