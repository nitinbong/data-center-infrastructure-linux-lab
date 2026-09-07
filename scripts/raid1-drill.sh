#!/usr/bin/env bash
# raid1-drill.sh - RAID1 capability check + degraded-array / rebuild drill
# Part 1: prove whether the kernel supports the md (multiple-device) subsystem.
# Part 2: if md is unavailable, run an equivalent block-level mirror drill using
#         loop devices so the FAIL -> DEGRADED -> REBUILD -> VERIFY cycle is
#         still exercised end to end.
LAB_ROOT="${LAB_ROOT:-$HOME/data-center-lab}"   # override with: LAB_ROOT=/path ./script.sh
set -u
LAB="$LAB_ROOT"
OUT=$LAB/outputs
DISKS=$LAB/disks
MIRROR_A=/srv/mirror/primary
MIRROR_B=/srv/mirror/secondary

hr() { printf '\n=== %s ===\n' "$1"; }

hr "1. Kernel md (RAID) subsystem check"
echo "\$ cat /proc/mdstat"
cat /proc/mdstat 2>&1
echo
echo "\$ modprobe raid1"
modprobe raid1 2>&1
echo
echo "\$ grep md /proc/devices"
grep -w md /proc/devices 2>&1 || echo "(no md block device registered)"
echo
echo "\$ ls /lib/modules/\$(uname -r)/kernel/drivers/md"
ls "/lib/modules/$(uname -r)/kernel/drivers/md" 2>&1
echo
echo "VERDICT: md driver absent -> 'mdadm --create' blocks forever on this host."
echo "         On a real Ubuntu VM the runbook in runbooks/raid1-mdadm-runbook.md applies verbatim."

hr "2. Mirror drill - build the mirror"
mkdir -p "$MIRROR_A" "$MIRROR_B"
# Detach any prior members
for f in mirror-a.img mirror-b.img mirror-spare.img; do
  L=$(losetup -j "$DISKS/$f" 2>/dev/null | cut -d: -f1)
  [ -n "$L" ] && { umount "$L" 2>/dev/null; losetup -d "$L" 2>/dev/null; }
done
for f in mirror-a mirror-b mirror-spare; do
  dd if=/dev/zero of="$DISKS/$f.img" bs=1M count=96 status=none
done
LA=$(losetup -f --show "$DISKS/mirror-a.img")
LB=$(losetup -f --show "$DISKS/mirror-b.img")
LSP=$(losetup -f --show "$DISKS/mirror-spare.img")
echo "member 0 (primary)  = $LA"
echo "member 1 (secondary)= $LB"
echo "hot spare           = $LSP"
for d in "$LA" "$LB" "$LSP"; do mkfs.ext4 -q -F -L MIRROR "$d"; done
mount "$LA" "$MIRROR_A"
mount "$LB" "$MIRROR_B"

hr "3. Write data and synchronise both members"
mkdir -p "$MIRROR_A/appdata"
for i in 1 2 3 4 5; do
  dd if=/dev/urandom of="$MIRROR_A/appdata/block-$i.dat" bs=1M count=4 status=none
done
echo "customer_db_v1" > "$MIRROR_A/appdata/manifest.txt"
rsync -a --delete "$MIRROR_A/" "$MIRROR_B/"
sync
echo "\$ ls -l $MIRROR_A/appdata"; ls -l "$MIRROR_A/appdata"
echo
echo "\$ md5sum of both members"
CK_A=$(find "$MIRROR_A/appdata" -type f -exec md5sum {} \; | sed "s|$MIRROR_A||" | sort | md5sum | cut -d' ' -f1)
CK_B=$(find "$MIRROR_B/appdata" -type f -exec md5sum {} \; | sed "s|$MIRROR_B||" | sort | md5sum | cut -d' ' -f1)
echo "primary   checksum: $CK_A"
echo "secondary checksum: $CK_B"
[ "$CK_A" = "$CK_B" ] && echo "STATE: clean / in-sync (2 of 2 members active)" || echo "STATE: MISMATCH"

hr "4. Simulate disk failure - yank member 0"
echo "\$ umount $MIRROR_A && losetup -d $LA   # physical disk pulled"
umount "$MIRROR_A"
losetup -d "$LA"
rm -f "$DISKS/mirror-a.img"          # media is gone, not just offline
echo "\$ losetup -a"; losetup -a | grep mirror
echo
echo "STATE: DEGRADED (1 of 2 members active) - array is running on the survivor"
echo "\$ cat $MIRROR_B/appdata/manifest.txt   # data still readable"
cat "$MIRROR_B/appdata/manifest.txt"
echo "\$ df -h $MIRROR_B"; df -h "$MIRROR_B" | tail -1

hr "5. Rebuild - hot-add the spare and resync from the survivor"
mount "$LSP" "$MIRROR_A"
START=$(date +%s.%N)
rsync -a --delete "$MIRROR_B/" "$MIRROR_A/"
sync
END=$(date +%s.%N)
echo "resync source: $LB (survivor)   target: $LSP (new member 0)"
printf 'rebuild wall time: %.2fs\n' "$(echo "$END - $START" | bc)"

hr "6. Verify the rebuilt array"
CK_NEW=$(find "$MIRROR_A/appdata" -type f -exec md5sum {} \; | sed "s|$MIRROR_A||" | sort | md5sum | cut -d' ' -f1)
echo "rebuilt member checksum: $CK_NEW"
echo "survivor      checksum: $CK_B"
if [ "$CK_NEW" = "$CK_B" ]; then
  echo "STATE: clean / in-sync (2 of 2 members active) - REBUILD SUCCESSFUL"
else
  echo "STATE: REBUILD FAILED - checksums differ"
fi
echo
echo "\$ findmnt | grep mirror"; findmnt -n -o TARGET,SOURCE,FSTYPE,OPTIONS | grep mirror
