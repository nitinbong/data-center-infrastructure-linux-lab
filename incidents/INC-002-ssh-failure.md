# INC-002 — SSH key authentication rejected on app01

| Field | Value |
|---|---|
| **Incident ID** | INC-002 |
| **Affected node** | app01 (10.10.10.12) |
| **Severity / priority** | High — no interactive or automated administrative access |
| **Detected by** | `fleet-monitor.py` reporting app01 as UNKNOWN (collection failed) |
| **Duration** | ~5 minutes, detection to verified restoration |
| **Evidence** | `evidence/inc-02-ssh.txt`, `evidence/11-sshd-app01.log`, `screenshots/INC-002-root-cause.png` |
| **Reproduce** | `sudo bash scripts/incident-02-ssh.sh` |

## Issue

`/home/sysadmin` was restored from a backup that did not preserve permissions,
leaving `~/.ssh` at mode `0777` and `authorized_keys` at `0666`. sshd runs with
`StrictModes yes` and refused to trust the key file, so all key-based logins
failed.

## Symptoms

```
$ ssh -o BatchMode=yes 10.10.10.12 hostname
sysadmin@10.10.10.12: Permission denied (publickey,password,keyboard-interactive).
ssh exit=255
```

Password authentication was still technically offered, but automation runs with
`BatchMode=yes` and cannot use it, so all scripted access was broken and app01
went dark in monitoring.

## Investigation

1. **Transport vs authentication** — ping succeeded and TCP/22 accepted
   connections, so the network, the firewall rule and sshd itself were all fine.
   That narrowed the problem to authentication immediately.
2. **Client view** — `ssh -vv` showed the correct key being offered and rejected
   by the server, ruling out a wrong key path, a missing key, a wrong username,
   or the wrong public key in `authorized_keys`.
3. **Server view** — the sshd log gave the cause directly:
   `Authentication refused: bad ownership or modes for file /home/sysadmin/.ssh/authorized_keys`.
   The client can only report *that* authentication failed; only the server knows
   *why*.
4. **Effective policy** — `sshd -T` confirmed `strictmodes yes` and
   `allowgroups devops sudo`; `id sysadmin` confirmed group membership was valid,
   ruling out a second plausible cause.
5. **Actual state** — `ls -ld` showed `.ssh` world-writable at `0777` and
   `authorized_keys` world-writable at `0666`.

## Commands / checks used

```bash
ping -c 2 -W 2 10.10.10.12
nc -z -w 3 10.10.10.12 22                 # transport check
ssh -vv -o BatchMode=yes 10.10.10.12      # client-side trace
tail -n +N <sshd log> | grep -Ei 'refused|bad ownership|Failed'
sshd -T -f <config> | grep -Ei '^(strictmodes|pubkey|authorizedkeysfile|allowgroups)'
ls -ld /home/sysadmin /home/sysadmin/.ssh /home/sysadmin/.ssh/authorized_keys
id sysadmin
```

## Root cause

`StrictModes yes` (the default) refuses to use an `authorized_keys` file writable
by anyone other than its owner, or one whose parent directories are group- or
world-writable. The reasoning is sound: a user who can write to `authorized_keys`
can append their own public key and impersonate the account permanently. The
restore left those permissions wide open, so sshd ignored the key entirely.

## Resolution

```bash
chown -R sysadmin:sysadmin /home/sysadmin
chmod 750 /home/sysadmin
chmod 700 /home/sysadmin/.ssh
chmod 600 /home/sysadmin/.ssh/authorized_keys
chmod 600 /home/sysadmin/.ssh/id_ed25519
chmod 644 /home/sysadmin/.ssh/id_ed25519.pub
```

Setting `StrictModes no` would have made the error disappear while removing a
real protection and leaving the account impersonable. It was not used.

## Validation

```
$ ssh -o BatchMode=yes 10.10.10.12 'echo login OK as $(whoami) from $SSH_CLIENT'
login OK as sysadmin from 10.10.10.11 59040 22
```

`fleet-monitor.py` re-run: both nodes collected, `FLEET: ALL SYSTEMS OK`.

## Preventive action

1. Preserve permissions during backup and restore (`tar -p`, `rsync -a`,
   `cp -a`); correct the restore procedure, not just this directory.
2. Extend the permissions assertion in `health-check.sh` (which already flags
   world-writable files under `/etc`) to cover `~/.ssh` for automation accounts.
3. Document a break-glass path. With key auth broken and `PermitRootLogin no`,
   recovery depended on host-level access.
4. Alert on monitoring gaps, not only on failures: a node reporting UNKNOWN is as
   serious as one reporting CRITICAL. `fleet-monitor.py` exits 3 for this case.
