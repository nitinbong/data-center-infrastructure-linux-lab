#!/usr/bin/env bash
# INC-004 - /srv/data reaches 100% and stays full after the obvious cleanup
# Two-stage fault: a bulk export file fills the volume, and a still-running
# process holds an already-deleted log file open, so deleting it frees nothing.
LAB_ROOT="${LAB_ROOT:-$HOME/data-center-lab}"   # override with: LAB_ROOT=/path ./script.sh
sec() { printf '\n########## %s ##########\n' "$1"; }
w() { printf '\n[web01]$ %s\n' "$*"; timeout 25 ip netns exec web01 sh -c "$*" 2>&1; }
VOL=/srv/data

sec "0. PRE-CHECK - volume healthy"
w "df -h $VOL"
w "du -sh $VOL/*"

sec "1. FAULT INJECTION"
rm -f $VOL/uploads/* $VOL/logs/* $VOL/backups/* 2>/dev/null
echo "1a. an application starts writing a log and keeps the file open"
python3 -c "
import os,time
f=open('$VOL/logs/app.log','wb')
f.write(b'x'*(120*1024*1024)); f.flush(); os.fsync(f.fileno())
open('/tmp/holder.pid','w').write(str(os.getpid()))
time.sleep(1200)          # process stays alive, file descriptor stays open
" >/dev/null 2>&1 </dev/null &
sleep 4
echo "  writer pid $(cat /tmp/holder.pid 2>/dev/null) holding $VOL/logs/app.log open"

echo
echo "1b. an overnight bulk export lands on the same volume"
dd if=/dev/zero of=$VOL/backups/bulk-export.tar bs=1M count=200 2>&1 | tail -2

sec "2. SYMPTOM - the volume is full and writes fail"
w "df -h $VOL"
echo "As the application user (deploy):"
w "su deploy -c \"echo 'new record' > $VOL/uploads/deploy-write-test.csv\"; echo \"write exit=\$?\""
w "su deploy -c \"dd if=/dev/zero of=$VOL/uploads/probe.tmp bs=1M count=2\" 2>&1 | head -3"
echo
echo "As root, the same write still succeeds:"
w "echo 'root can still write' > $VOL/uploads/root-probe.txt; echo \"write exit=\$?\""
echo "NOTE: ext4 reserves 5% of blocks for root (tune2fs -m). Unprivileged"
echo "      services hit ENOSPC first, which is exactly the point of the reserve:"
echo "      root keeps enough room to log in and clean up."
echo
echo "Health check:"
timeout 60 ip netns exec web01 bash $LAB_ROOT/monitoring/health-check.sh -q -p 10.10.10.12 -s sshd -l "80 22" 2>&1 | tail -8

sec "3. TRIAGE"
echo "--- 3a. Is it space or inodes? Both present as ENOSPC ---"
w "df -h $VOL"
w "df -i $VOL"
echo "FINDING: blocks are 100% used, inodes are nearly empty -> a few large"
echo "         files, not millions of small ones."
echo
echo "--- 3b. Walk down the tree to the offenders ---"
w "du -h --max-depth=1 $VOL | sort -rh"
w "du -ah $VOL | sort -rh | head -6"
w "find $VOL -xdev -type f -size +50M -exec ls -lh {} + 2>/dev/null"
echo
echo "--- 3c. Check for recently grown files ---"
w "find $VOL -xdev -type f -mmin -10 -size +10M -exec ls -lh {} + 2>/dev/null"

sec "4. FIX - first pass: remove the bulk export"
w "rm -f $VOL/backups/bulk-export.tar"
w "df -h $VOL"
echo "Some space reclaimed, but the volume is still heavily used."

sec "5. THE TRAP - deleting the log frees nothing"
echo "The obvious next step is to delete the large log file:"
w "ls -lh $VOL/logs/app.log"
w "rm -f $VOL/logs/app.log"
w "du -sh $VOL"
w "df -h $VOL"
echo
echo "PROBLEM: du now reports almost nothing, but df still reports the space as"
echo "used. du walks directory entries; df asks the filesystem. When a file is"
echo "unlinked while a process still holds it open, the directory entry is gone"
echo "but the inode and its blocks are not released until the last descriptor"
echo "closes. du cannot see it; df can."

sec "6. FIND THE PROCESS HOLDING THE DELETED FILE"
echo "--- 6a. Scan /proc for deleted files still held open ---"
printf '\n[web01]$ for p in /proc/[0-9]*; do ls -l $p/fd 2>/dev/null | grep deleted; done\n'
for p in /proc/[0-9]*; do
  pid=${p#/proc/}
  ls -l "$p/fd" 2>/dev/null | grep '(deleted)' | while read -r line; do
    echo "  pid=$pid  $line"
  done
done | head -8
echo
if command -v lsof >/dev/null 2>&1; then
  echo "--- 6b. Same answer via lsof ---"
  w "lsof +L1 2>/dev/null | head -5"
else
  echo "--- 6b. lsof is not installed; on a production host:  lsof +L1  ---"
  echo "        (lists open files with a link count of 0 = deleted but held)"
fi
HPID=$(cat /tmp/holder.pid 2>/dev/null)
echo
echo "--- 6c. Identify the holder before acting on it ---"
w "ps -o pid,ppid,user,etime,rss,cmd -p ${HPID:-1}"
w "ls -l /proc/${HPID:-1}/fd | grep deleted"
w "ls -l /proc/${HPID:-1}/exe"

sec "7. RECLAIM THE SPACE"
echo "Two safe options: truncate the descriptor in place (keeps the process"
echo "running), or restart the process so it closes the descriptor."
echo
echo "Option A - truncate through the descriptor, no restart required:"
FD=$(ls -l /proc/${HPID:-1}/fd 2>/dev/null | grep deleted | head -1 | awk '{print $9}')
echo "  descriptor: /proc/$HPID/fd/$FD"
w ": > /proc/$HPID/fd/$FD; echo \"truncate exit=\$?\""
w "df -h $VOL"

sec "8. VERIFY"
w "df -h $VOL"
w "df -i $VOL"
w "du -sh $VOL"
w "su deploy -c \"echo 'new record' > $VOL/uploads/deploy-write-test.csv\"; echo \"write exit=\$?\"; cat $VOL/uploads/deploy-write-test.csv"
timeout 60 ip netns exec web01 bash $LAB_ROOT/monitoring/health-check.sh -q -p 10.10.10.12 -s sshd -l "80 22" 2>&1 | tail -5
echo
echo "SERVICE RESTORED"
kill "$HPID" 2>/dev/null; rm -f /tmp/holder.pid $VOL/uploads/probe.tmp $VOL/uploads/root-probe.txt
