# INC-005 — nginx returns 403 Forbidden after a document-root permissions change

| Field | Value |
|---|---|
| **Incident ID** | INC-005 |
| **Affected node** | web01 (10.10.10.11) |
| **Severity / priority** | Critical — every page returned 403; content editing also blocked |
| **Detected by** | `health-check.sh` HTTP check reporting `responded HTTP 403` |
| **Duration** | ~5 minutes |
| **Evidence** | `evidence/inc-05-permissions.txt`, `screenshots/INC-005-triage.png`, `screenshots/INC-005-resolution.png` |
| **Reproduce** | `sudo bash scripts/incident-05-permissions.sh` |

## Issue

A "hardening" change set the document root to `0700 root:root`. The nginx worker
processes run as `www-data` and could no longer traverse into the directory, so
every request returned 403. A second, related fault left a published page owned
`deploy:deploy` at mode `0640`, locking the content editor out of her own file.

## Symptoms

```
$ curl -s -o /dev/null -w 'HTTP %{http_code}\n' http://10.10.10.11/
HTTP 403

$ curl -s http://10.10.10.11/ | head -3
<html>
<head><title>403 Forbidden</title></head>

  CRIT  http:http://10.10.10.11/  responded HTTP 403
 OVERALL: CRITICAL - 1 issue(s)

[as webdev] $ echo '<h1>updated</h1>' > /srv/webcontent/notice.html
bash: /srv/webcontent/notice.html: Permission denied
```

## Investigation

1. **A 403 is not an outage.** `ss -tlnp` showed nginx listening and the master
   process running. The request reached the server and was refused, which
   separates this from INC-003 where nothing was listening.

   Reading the status code correctly saves the first five minutes of any web
   incident: **403** = permissions, **404** = wrong path or document root,
   **502/504** = upstream, **connection refused** = nothing listening.
2. **The error log named the file and the errno** —
   `"/srv/webcontent/index.html" is forbidden (13: Permission denied)`.
   Errno 13 is `EACCES`. Note that it names the file, while the actual block was
   one level up.
3. **Identify the user that opens files.** `ps -o pid,user,cmd -C nginx` showed
   the master running as root (to bind port 80) and the **workers** dropped to
   `www-data`. Permissions must satisfy the worker, and checking the running
   process is more reliable than reading the config.
4. **Reproduce as that user and walk the path.** `su -s /bin/sh www-data -c "ls
   /srv/webcontent"` returned `Permission denied`, and `namei -l` showed every
   component's ownership and mode — necessary because a file can be perfectly
   readable while an ancestor directory denies traversal.
5. **Part B.** `ls -l` showed `notice.html` as `-rw-r----- deploy:deploy` and
   `id webdev` showed membership of `webadmins`, not `deploy` — so neither the
   owner nor group bits applied to her, only `other`, which has no write bit.

## Commands / checks used

```bash
ss -tlnp sport = :80 ; pgrep -a nginx
tail -3 <nginx error log>
ps -o pid,user,cmd -C nginx
id www-data ; id webdev
su -s /bin/sh www-data -c "ls /srv/webcontent"
su -s /bin/sh www-data -c "cat /srv/webcontent/index.html >/dev/null"
namei -l /srv/webcontent/index.html
ls -ld /srv/webcontent ; ls -l /srv/webcontent/notice.html
getfacl /srv/webcontent
```

## Root cause

**Fault A:** `/srv/webcontent` was set to `0700 root:root`. `www-data` is neither
the owner nor a member of the owning group, so only the `other` bits applied —
and `0700` grants `other` nothing, not even the execute bit required to traverse
into the directory.

**Fault B:** the published file was chowned to `deploy:deploy` at `0640`, removing
it from the shared `webadmins` group that the SGID bit on the directory exists to
enforce. The group model was correct; the file had been moved outside it.

## Resolution

```bash
chown root:webadmins /srv/webcontent
chmod 2775 /srv/webcontent                       # rwxrwsr-x, SGID preserves the shared group
chown deploy:webadmins /srv/webcontent/notice.html
chmod 664 /srv/webcontent/notice.html
```

`chmod -R 777` would clear the 403 and simultaneously allow every local account,
including unprivileged service accounts, to rewrite served content. It was not
used. The correct fix is group membership plus the SGID bit.

## Validation

```
$ curl -s -o /dev/null -w 'HTTP %{http_code}\n' http://10.10.10.11/
HTTP 200
$ curl -s -o /dev/null -w 'notice.html HTTP %{http_code}\n' http://10.10.10.11/notice.html
notice.html HTTP 200

[as www-data] $ cat /srv/webcontent/index.html >/dev/null      → exit 0
[as webdev]   $ echo '<h1>updated by webdev</h1>' > notice.html → exit 0

$ ls -l /srv/webcontent/notice.html
-rw-rw-r--+ 1 deploy webadmins 27 notice.html

# SGID still enforcing the shared group on new files:
[as webdev] $ touch /srv/webcontent/verify-sgid.html
-rw-rw-r--+ 1 webdev webadmins 0 verify-sgid.html
```

Health check re-run: `OVERALL: OK - all checks passed`.

## Preventive action

1. Document the intended permission model for the document root
   (`2775 root:webadmins` plus the default ACL) so hardening changes have a
   baseline to compare against.
2. Deployment tooling should set `deploy:webadmins` and let the SGID bit handle
   group inheritance; never chown published files out of the shared group.
3. Set the deploy account's umask to `002` so new files are group-writable by
   default.
4. Keep the HTTP status assertion in the health check — a process check and a
   port check would both have reported healthy during this incident.
5. Treat `chmod 777` as a review failure rather than a fix.
