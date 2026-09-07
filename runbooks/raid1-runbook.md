# RAID1 with mdadm — runbook

**Why this is a runbook and not a capture.** The lab kernel has no `md` driver.
This was verified rather than assumed (`evidence/07-raid1-mirror-drill.txt`):

```
$ cat /proc/mdstat
cat: /proc/mdstat: No such file or directory
$ modprobe raid1
modprobe: FATAL: Module raid1 not found in directory /lib/modules/6.18.44-fc-v24
$ grep md /proc/devices
(no md block device registered)
```

With no `md` block device registered, `mdadm --create` blocks forever — it did,
and had to be killed. So the lab demonstrated the **concepts** with an equivalent
loop-device mirror drill (build → fail a member → run degraded → hot-add a spare →
resync → verify by checksum), and the `mdadm` procedure below is documented for a
real VM. Every command here applies unchanged on hardware or a normal VM.

---

## 1. Create a RAID1 array

```bash
# Inspect candidate devices first
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT
wipefs -a /dev/sdb /dev/sdc          # clear old signatures (destructive)

mdadm --create --verbose /dev/md0 \
      --level=1 --raid-devices=2 /dev/sdb /dev/sdc

cat /proc/mdstat                      # watch the initial sync
mdadm --detail /dev/md0
```

`/proc/mdstat` during the initial resync:

```
Personalities : [raid1]
md0 : active raid1 sdc[1] sdb[0]
      10476544 blocks super 1.2 [2/2] [UU]
      [====>................]  resync = 21.3% (2234368/10476544) finish=1.2min
```

`[2/2] [UU]` means both members are present and up. `[2/1] [U_]` is a degraded
array. The array is usable during the initial sync, just slower.

## 2. Filesystem and mount

```bash
mkfs.ext4 -L RAIDDATA /dev/md0
mkdir -p /srv/data
mount /dev/md0 /srv/data
blkid /dev/md0                        # get the UUID
```

Persist by **UUID**, never by device name — `/dev/md0` can be renumbered on boot:

```
# /etc/fstab
UUID=<uuid-from-blkid>  /srv/data  ext4  defaults,nofail  0  2
```

`nofail` keeps a failed data volume from blocking the boot into a rescue prompt.

## 3. Persist the array itself

```bash
mdadm --detail --scan | tee -a /etc/mdadm/mdadm.conf
update-initramfs -u                   # Debian/Ubuntu: array must assemble at boot
```

Skipping `update-initramfs` is the classic mistake: the array works perfectly
until the first reboot, then fails to assemble.

## 4. Monitor

```bash
cat /proc/mdstat
mdadm --detail /dev/md0
mdadm --monitor --scan --daemonise --mail=ops@example.com
```

Set `MAILADDR` in `/etc/mdadm/mdadm.conf`. **A mirror that silently loses a
member is worse than no mirror**, because you believe you are protected. Alerting
on degradation is the entire value of RAID1 in practice.

A scheduled consistency check catches latent bad blocks before a rebuild needs them:

```bash
echo check > /sys/block/md0/md/sync_action
cat /sys/block/md0/md/mismatch_cnt      # should be 0
```

Ubuntu ships `mdcheck_start.timer` / `mdcheck_continue.timer` for this.

## 5. Simulate and handle a disk failure

```bash
mdadm --manage /dev/md0 --fail /dev/sdc      # mark faulty
mdadm --manage /dev/md0 --remove /dev/sdc    # remove from the array
cat /proc/mdstat
```

Degraded state:

```
md0 : active raid1 sdb[0]
      10476544 blocks super 1.2 [2/1] [U_]
```

The filesystem stays mounted and readable/writable on the surviving member —
which is the point of the mirror. This maps directly to stage 4 of the lab drill,
where data on the survivor was still readable after the member was pulled.

## 6. Replace and rebuild

```bash
mdadm --manage /dev/md0 --add /dev/sdd       # new disk
watch -n2 cat /proc/mdstat                   # rebuild progress
```

```
md0 : active raid1 sdd[2] sdb[0]
      10476544 blocks super 1.2 [2/1] [U_]
      [=========>...........]  recovery = 47.8% finish=0.8min speed=…
```

Tune rebuild speed if it competes with production I/O:

```bash
sysctl -w dev.raid.speed_limit_min=50000
sysctl -w dev.raid.speed_limit_max=200000
```

## 7. Hot spares

```bash
mdadm --add-spare /dev/md0 /dev/sde
mdadm --detail /dev/md0 | grep -i spare
```

With a spare attached, md begins the rebuild automatically the moment a member
fails — no human in the loop. This is the behaviour the lab drill imitated by
attaching a pre-made spare device and resyncing onto it.

## 8. Grow, stop, and clean up

```bash
mdadm --grow /dev/md0 --raid-devices=3        # 3-way mirror
resize2fs /dev/md0                            # after growing the underlying array
umount /srv/data && mdadm --stop /dev/md0
mdadm --zero-superblock /dev/sdb              # before reusing a disk elsewhere
```

## What the lab drill demonstrated instead

`scripts/raid1-drill.sh` runs the full lifecycle on loop devices:

| Stage | RAID1 concept | Verified by |
|---|---|---|
| Build two members, sync | initial resync | matching md5 of both members |
| Yank member 0 (`losetup -d`, image deleted) | disk failure | `losetup -a` shows one member gone |
| Read from survivor | degraded operation | `cat manifest.txt` succeeds, `df` works |
| Attach spare, resync | hot-spare rebuild | rebuild timed, source/target logged |
| Compare checksums | consistency check | rebuilt member matches survivor exactly |

The mechanism is different (userspace copy, not kernel block mirroring) and it is
labelled as such in the output. The operational lifecycle — detect, run degraded,
rebuild, verify — is the part that transfers.
