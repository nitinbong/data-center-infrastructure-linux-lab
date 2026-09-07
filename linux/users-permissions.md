# Users, groups and permissions

Evidence: `evidence/02-users-permissions-firewall.txt`
Screenshots: `screenshots/03-users-permissions.png`, `screenshots/04-acls-and-sudo.png`

## Accounts and groups

| User | Primary group | Supplementary groups | Purpose |
|---|---|---|---|
| `sysadmin` | `sysadmin` | `sudo`, `devops` | administration, SSH between nodes |
| `deploy` | `deploy` | `devops`, `webadmins` | deployments, owns `/srv/data` |
| `webdev` | `webdev` | `webadmins` | content editing |
| `junior` | `junior` | `appteam` | unprivileged account used to test denials |

## Managed directories

| Path | Owner | Mode | Reason |
|---|---|---|---|
| `/srv/webcontent` | `root:webadmins` | `2775` | SGID so new files inherit `webadmins` |
| `/srv/data` | `deploy:devops` | `2775` | application data volume |
| `/srv/dropbox` | `root:root` | `1777` | sticky bit: users cannot delete each other's files |
| `/srv/secrets` | `sysadmin:sysadmin` | `0700` | owner-only |
| `/srv/secrets/app.env` | `sysadmin:sysadmin` | `0600` | owner-only |

POSIX ACLs extend the model without loosening the mode:

```bash
setfacl -m g:devops:rwx /srv/webcontent        # additional group access
setfacl -d -m g:webadmins:rwx /srv/webcontent  # default ACL applied to new files
```

## Validation performed

Each control was proven by test rather than assumed:

- **SGID inheritance** — `webdev` created a file in `/srv/webcontent` and it was
  owned `webdev:webadmins`, not `webdev:webdev`.
- **Mode enforcement** — `junior` reading `/srv/secrets/app.env` returned
  `Permission denied`.
- **sudo policy** — `sudo -l -U sysadmin` shows full access; `sudo -l -U junior`
  shows none.

## Principles applied

- Group membership and the SGID bit provide shared write access; `chmod 777` is
  never used. INC-005 covers a case where it would have been the tempting fix.
- Every path component needs `x` for a user to traverse it. `namei -l` is used to
  find which component denies access, since the error names the file rather than
  the directory that blocked it.
