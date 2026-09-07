# SSH configuration and administration

Evidence: `evidence/01-network-setup.txt`, `evidence/11-sshd-app01.log`
Screenshot: `screenshots/02-ssh-validation.png`

Each node runs its own `sshd` instance with its own host key and configuration,
bound to that node's address.

## Hardening applied

```
PermitRootLogin no
PubkeyAuthentication yes
AllowGroups devops sudo
LogLevel VERBOSE
X11Forwarding no
```

`StrictModes` is left at its default (`yes`), which enforces that `~/.ssh` is
`0700` and `authorized_keys` is `0600`. INC-002 covers what happens when those
modes are wrong.

## Key-based access

An ed25519 key pair was generated for `sysadmin` and authorised on app01, giving
passwordless administrative access from web01 and enabling automated collection
by `monitoring/fleet-monitor.py`, which runs with `BatchMode=yes`.

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519
ssh -o BatchMode=yes sysadmin@10.10.10.12 'echo connected as $(whoami)'
```

## Validation performed

| Check | Command | Result |
|---|---|---|
| Config syntax | `sshd -t -f <config>` | valid |
| Effective policy | `sshd -T -f <config>` | confirms `strictmodes`, `allowgroups`, `permitrootlogin` |
| Listener | `ss -tlnp` | bound to the node address on `:22` |
| Login | `ssh -o BatchMode=yes 10.10.10.12` | key accepted, session established |
| Server-side record | sshd log | `Accepted publickey for sysadmin from 10.10.10.11` |

## Troubleshooting notes

Separate transport from authentication before anything else: if TCP/22 accepts a
connection, the network and the firewall are not the problem. The client can only
report *that* authentication failed; the server log reports *why*. Full procedure
in `runbooks/troubleshooting-cheatsheet.md`.
