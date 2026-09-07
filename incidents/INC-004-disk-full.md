# INC-004 — /srv/data at 100% and still full after the obvious cleanup

| Field | Value |
|---|---|
| **Incident ID** | INC-004 |
| **Affected node** | web01 (10.10.10.11), volume `/srv/data` (ext4, 224 MB, loop device) |
| **Severity / priority** | High — application writes failing; HTTP service unaffected |
| **Detected by** | `health-check.sh` disk capacity check reporting CRITICAL at 100% |
| **Duration** | ~7 minutes, extended by a deletion that freed no space |
| **Evidence** | `evidence/inc-04-diskfull.txt`, `screenshots/INC-004-symptom.png`, `screenshots/INC-004-du-vs-df.png`, `screenshots/INC-004-resolution.png` |
| **Reproduce** | `sudo bash scripts/incident-04-diskfull.sh` |

## Issue

A bulk export plus a 120 MB application log filled `/srv/data`. Deleting both
files did not return the space, because a running process still held the log file
open.

## Symptoms

```
$ df -h /srv/data
/dev/loop1  224M  219M  0  100% /srv/data

[as deploy] $ echo 'new record' > /srv/data/uploads/deploy-write-test.csv
bash: echo: write error: No space left on device

[as deploy] $ dd if=/dev/zero of=/srv/data/uploads/probe.tmp bs=1M count=2
dd: error writing '/srv/data/uploads/probe.tmp': No space left on device

[as root]   $ echo 'root can still write' > /srv/data/uploads/root-probe.txt
write exit=0
```

**Why root still worked:** ext4 reserves 5% of blocks for root (`tune2fs -m`).
Unprivileged services hit `ENOSPC` first, which is the purpose of the reserve —
root keeps enough room to log in and clean up. A root shell that can still write
is not evidence that a volume is healthy.

## Investigation

1. **Space or inodes?** Both surface as `ENOSPC` but need different remediation.
   `df -h` showed 100% of blocks used while `df -i` showed 12 of 65536 inodes
   used — a few very large files, not millions of small ones.
2. **Locate the offenders.** `du --max-depth=1` then descending, plus `find` by
   size and by modification time, identified the bulk export and the log.
3. **First cleanup — partial.** Removing the 200 MB export reduced usage but the
   volume stayed heavily used.
4. **The contradiction.** After deleting the large log, `du` reported 36K while
   `df` still reported 121 MB used.

   `du` walks directory entries; `df` asks the filesystem. When a file is
   unlinked while a process still holds it open, the directory entry disappears
   but the inode and its blocks are not released until the last descriptor
   closes. A `du`/`df` disagreement is the signature of this condition.
5. **Find the holder.** Scanning `/proc` for open descriptors marked `(deleted)`
   identified the writing process, which was then identified with `ps` and
   `/proc/<pid>/exe` before any action was taken.

## Commands / checks used

```bash
df -h /srv/data ; df -i /srv/data
du -h --max-depth=1 /srv/data | sort -rh
du -ah /srv/data | sort -rh | head
find /srv/data -xdev -type f -size +50M -exec ls -lh {} +
find /srv/data -xdev -type f -mmin -10 -size +10M -exec ls -lh {} +
for p in /proc/[0-9]*; do ls -l $p/fd 2>/dev/null | grep '(deleted)'; done
# lsof +L1 gives the same answer where lsof is installed
ps -o pid,ppid,user,etime,rss,cmd -p <pid>
ls -l /proc/<pid>/exe
```

Captured result of the `/proc` scan:

```
pid=1723  l-wx------ 1 root root 64  3 -> /srv/data/logs/app.log (deleted)
```

## Root cause

Two unrelated large writes filled a small volume, and the log file was deleted
while its writer was still running, so its blocks stayed allocated. Underlying
conditions: no log rotation on `logs/app.log`, and backups written to the same
volume as application data with no size cap.

## Resolution

```bash
rm -f /srv/data/backups/bulk-export.tar     # reclaims immediately
: > /proc/1723/fd/3                          # truncate through the descriptor
```

Truncating through `/proc/<pid>/fd/<n>` releases the blocks without restarting
the holding process, which matters when the holder is a service that cannot be
bounced. Restarting the process is the alternative.

## Validation

```
$ df -h /srv/data
/dev/loop1  224M  40K  206M  1% /srv/data

$ df -i /srv/data
/dev/loop1  65536 inodes, 18 used, 1% IUse

[as deploy] $ echo 'new record' > /srv/data/uploads/deploy-write-test.csv
write exit=0
```

Health check re-run: `OVERALL: OK - all checks passed`.

## Preventive action

1. Rotate the log — a `logrotate` rule with `copytruncate`, or an application
   that reopens on SIGHUP, prevents unbounded growth and avoids this trap.
2. Separate backups from application data so bulk exports cannot starve the
   volume the application writes to.
3. Alert on the trend, not the wall. The health check warns at 80% and goes
   critical at 90%; `evidence/12-health-history.csv` provides data for growth-rate
   alerting.
4. Add a `du` vs `df` check to the runbook: when they disagree, go straight to
   `lsof +L1` rather than deleting more files.
5. Consider a smaller root reserve on large data volumes (`tune2fs -m 1`), but
   keep it non-zero so root can always recover the system.
