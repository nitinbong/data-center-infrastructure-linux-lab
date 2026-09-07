# Storage management

Evidence: `evidence/03-baseline-web01.txt`, `evidence/inc-04-diskfull.txt`

## Data volume

A 256 MB loop-backed ext4 volume is mounted at `/srv/data` on web01 and used for
application uploads, logs and backups.

```bash
dd if=/dev/zero of=data.img bs=1M count=256
LOOP=$(losetup -f --show data.img)
mkfs.ext4 -L LABDATA "$LOOP"
mount "$LOOP" /srv/data
```

Directories `uploads/`, `logs/` and `backups/` are owned `deploy:devops` at mode
`2775` so the shared group is inherited.

Persistence on a full Linux VM would use `/etc/fstab` keyed by UUID rather than
device name, since loop and disk numbering can change across reboots:

```
UUID=<blkid output>  /srv/data  ext4  defaults,nofail  0  2
```

`nofail` prevents a failed data volume from blocking boot. This entry is
documented but not applied in the lab — see `PROJECT-STATUS.md`.

## Inspection commands exercised

| Purpose | Command |
|---|---|
| Capacity | `df -h`, `df -hT` |
| Inodes | `df -i` |
| Usage by directory | `du -h --max-depth=1 /srv/data \| sort -rh` |
| Large files | `find /srv/data -xdev -type f -size +50M -exec ls -lh {} +` |
| Recently grown files | `find /srv/data -xdev -type f -mmin -10 -size +10M` |
| Device and filesystem | `losetup -a`, `blkid`, `findmnt -t ext4` |

## Monitoring

`monitoring/health-check.sh` checks **both** capacity and inodes per filesystem,
warning at 80% and going critical at 90%, and also flags unexpected read-only
mounts. Capacity and inode exhaustion both surface as `ENOSPC` but need different
remediation, so they are checked separately.

## Key finding from INC-004

`du` walks directory entries; `df` asks the filesystem. When a file is unlinked
while a process still holds it open, the blocks are not released until the last
descriptor closes — `du` reported 36K while `df` reported 121M used. The holder
was found by scanning `/proc/[0-9]*/fd` for `(deleted)` and the space reclaimed
by truncating through the descriptor, with no service restart. Full write-up in
`incidents/INC-004-disk-full.md`.

Also note ext4 reserves 5% of blocks for root, so unprivileged services hit
`ENOSPC` while root writes still succeed. A root shell that can still write is
not evidence that a volume is healthy.
