# Linux troubleshooting cheatsheet — organised by symptom

Built from the five incidents in this lab. The organising idea: **start from what
the symptom rules out**, not from a list of commands.

---

## Read the failure mode first

| Symptom | What it tells you | Go to |
|---|---|---|
| Connection **timed out** | Packets went nowhere — no host answered | Network |
| Connection **refused** | Host answered, nothing listening on that port | Service |
| **403 Forbidden** | Service ran, permissions denied the file | Permissions |
| **404 Not Found** | Service ran, path or doc root is wrong | Config |
| **502 / 504** | Front-end is fine, upstream is not | Upstream service |
| `Permission denied` (errno 13) | Ownership, mode, or a parent directory | Permissions |
| `No space left on device` | Blocks **or** inodes exhausted | Storage |
| `Address already in use` | Something else owns the port | Service |
| Auth fails but port is open | Transport is fine — it is authentication | SSH |

---

## Network — "I can't reach it"

Work up the stack; do not jump to the firewall.

```bash
ip -brief link show          # 1. Is the link UP / LOWER_UP?
ip -s link show <dev>        #    errors, drops, carrier losses
ip -brief addr show          # 2. Do we hold the address we think we do?
ip route show                # 3. Is there a route?
ip route get <dst>           #    which route would this packet actually take
ip neigh flush all && ping -c1 <dst> && ip neigh show
                             # 4. ARP: REACHABLE = someone owns that IP
                             #    INCOMPLETE/FAILED = nobody does
ss -tlnp                     # 5. Is the service bound, and to which address?
ss -tnp state established    #    who is currently connected
ss -s                        #    socket summary
```

**Flush the neighbour cache before trusting it** — a stale `REACHABLE` entry
after an address change sends you down the wrong path (INC-001).

A socket bound to an address the host no longer holds still shows as `LISTEN`.
Local socket state is not reachability.

Firewall side:

```bash
iptables -L INPUT -n -v --line-numbers    # packet counters show what is being hit
ufw status verbose
```

Counters are the tell: a rule with zero packets is not the one blocking you.

---

## Service — "it's down / it won't start"

```bash
systemctl status <svc> -l --no-pager
journalctl -u <svc> -n 50 --no-pager
journalctl -u <svc> -p err --since "20 min ago"

nginx -t          # validate BEFORE restarting — always
sshd -t
visudo -c

ss -tlnp sport = :80          # who owns the port
ps -o pid,ppid,user,etime,cmd -p <pid>
ls -l /proc/<pid>/exe /proc/<pid>/cwd     # what the process actually is
```

Prefer `reload` over `restart` — reload never releases the listening socket, which
is how a rogue process seizes a port during a maintenance window (INC-003).

Identify a process before killing it. `/proc/<pid>/exe` does not lie; a command
line can.

---

## Storage — "disk full"

```bash
df -h                   # blocks
df -i                   # inodes — both surface as ENOSPC, different fixes
df -hT -x tmpfs -x devtmpfs

du -h --max-depth=1 /path | sort -rh      # descend deliberately
du -ah /path | sort -rh | head
find /path -xdev -type f -size +100M -exec ls -lh {} +
find /path -xdev -type f -mmin -60 -size +10M -exec ls -lh {} +
```

**If `du` and `df` disagree, a deleted file is still held open:**

```bash
lsof +L1                                          # link count 0 = deleted, still open
for p in /proc/[0-9]*; do ls -l $p/fd 2>/dev/null | grep '(deleted)'; done
: > /proc/<pid>/fd/<n>                            # reclaim without restarting
```

Also check: read-only remounts (`findmnt -rn -o TARGET,OPTIONS | grep ' ro'`),
and remember ext4 reserves 5% for root, so root writes succeed after unprivileged
ones start failing.

```bash
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT
blkid ; findmnt -t ext4 ; losetup -a
mount -o remount,rw /path
```

---

## Permissions — "Permission denied / 403"

```bash
ls -ld /path/to/dir ; ls -l /path/to/file
namei -l /full/path/to/file       # EVERY component of the path
id <user> ; groups <user>
getfacl /path                      # a '+' in ls output means ACLs are set
sudo -l -U <user>
su -s /bin/sh <serviceuser> -c "cat /path/file"   # reproduce as the real user
ps -o user= -C nginx               # which user the workers actually run as
```

Key points learned the hard way:

- The error names the **file**, but the block is often a **parent directory**
  missing `x`. `namei -l` finds it.
- Web servers: the master runs as root to bind the port, workers drop to
  `www-data`. Permissions must satisfy the worker.
- `chmod 777` is never the fix. Fix group membership; use SGID (`chmod 2775`) so
  new files inherit the shared group; use ACLs for the exceptions.
- Special bits: `4000` setuid, `2000` setgid, `1000` sticky (`1777` on shared
  writable dirs so users cannot delete each other's files).

---

## SSH — "I'm locked out"

```bash
# 1. Separate transport from authentication
ping -c2 <host>
nc -z -w3 <host> 22                       # open => not a network problem

# 2. Client view: which key is offered, what comes back
ssh -vv -o BatchMode=yes user@host

# 3. Server view — authoritative
journalctl -u ssh -n 50          # or the sshd log file
# "Authentication refused: bad ownership or modes for file …"

# 4. Effective config, not the file as written
sshd -T -f /etc/ssh/sshd_config | grep -Ei '^(strictmodes|pubkey|authorizedkeysfile|allowgroups|permitrootlogin)'
sshd -t                                   # syntax check before reloading
```

Required modes (`StrictModes yes` enforces these):

| Path | Mode |
|---|---|
| `~` | `0755` or stricter, **not** group/world-writable |
| `~/.ssh` | `0700` |
| `~/.ssh/authorized_keys` | `0600` |
| `~/.ssh/id_*` (private) | `0600` |

Never "fix" this with `StrictModes no`. Fix the permissions.

---

## CPU, memory, load

```bash
uptime ; cat /proc/loadavg          # compare load against nproc
nproc ; lscpu
vmstat 1 5                          # r = runnable, b = blocked, wa = I/O wait
top -b -n1 | head -15
ps -eo pid,ppid,user,pcpu,pmem,rss,stat,comm --sort=-pcpu | head
free -h                             # 'available' is the number that matters
ps -eo pid,user,pmem,rss,comm --sort=-rss | head
```

Load average is per-runnable-task, not a percentage — divide by core count.
High load with high `wa` in `vmstat` is I/O, not CPU. Check `SwapFree` too:
heavy swapping presents as "everything is slow" with unremarkable CPU numbers.

---

## The general method

1. **Reproduce it** and note the exact error text and exit code.
2. **Let the symptom eliminate layers** before touching anything.
3. **Check the server-side log** — the client only knows *that* it failed.
4. **Reproduce as the affected user**, not as root. Root hides permission and
   quota problems (both `EACCES` and `ENOSPC`).
5. **Change one thing at a time**, and verify after each change. Three of the
   five incidents here had more than one fault; fixing the first only revealed
   the next.
6. **Verify with the same command that showed the failure**, then with an
   end-to-end check (`curl`, health script), not just "the process is running".
