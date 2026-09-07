# RAID1 simulation

Evidence: `evidence/07-raid1-mirror-drill.txt`
Screenshots: `screenshots/09-raid-capability-check.png`, `screenshots/10-raid1-simulation.png`
Script: `scripts/raid1-drill.sh`
Real procedures: `runbooks/raid1-runbook.md`

## Scope — read this first

**No real `mdadm` RAID1 array was created in this lab, and none is claimed.**

What was done:

1. **Verified** that the lab kernel cannot support `md` RAID, and captured that
   verification as evidence.
2. **Simulated the RAID1 operational lifecycle** on loop-backed storage —
   member failure, degraded operation, replacement, resynchronisation and
   validation.
3. **Documented the equivalent `mdadm` procedures** for implementation on a full
   Linux VM, in `runbooks/raid1-runbook.md`.

## 1. Capability check

The limitation was verified rather than assumed:

```
$ cat /proc/mdstat
cat: /proc/mdstat: No such file or directory

$ modprobe raid1
modprobe: FATAL: Module raid1 not found

$ grep md /proc/devices
(no md block device registered)
```

With no `md` block device registered, `mdadm --create` blocks indefinitely — it
did, and the process had to be terminated. That result is part of the evidence
rather than something worked around silently.

## 2. Lifecycle simulation

`scripts/raid1-drill.sh` builds two loop-backed ext4 members plus a spare and
exercises the full cycle:

| Stage | RAID1 concept modelled | Verified by |
|---|---|---|
| Build and synchronise two members | initial sync | matching MD5 across both members |
| Detach member 0 and delete its image | member failure | `losetup -a` shows one member remaining |
| Read and report from the survivor | degraded operation | data readable, `df` reports normally |
| Attach the spare and resynchronise | replacement and rebuild | rebuild source, target and duration logged |
| Compare checksums | consistency validation | rebuilt member matches the survivor exactly |

Captured result:

```
STATE: clean / in-sync (2 of 2 members active)
STATE: DEGRADED (1 of 2 members active) - array is running on the survivor
STATE: clean / in-sync (2 of 2 members active) - REBUILD SUCCESSFUL
```

## 3. What transfers and what does not

**Does not transfer:** the mechanism. This is a userspace copy between two
filesystems, not kernel block-level mirroring. There is no `md` device, no
superblock, no automatic failure detection and no write-time redundancy.

**Does transfer:** the operational lifecycle and the reasoning — recognising a
degraded array, understanding that service continues on the survivor, replacing a
member, monitoring a rebuild, and validating consistency afterwards rather than
assuming it.

The real commands for each of those stages (`mdadm --create`, `--fail`,
`--remove`, `--add`, `--add-spare`, `/proc/mdstat`, `mdadm.conf`,
`update-initramfs`, `mdadm --monitor`) are documented in
`runbooks/raid1-runbook.md` and are ready to run on a full Linux VM.
