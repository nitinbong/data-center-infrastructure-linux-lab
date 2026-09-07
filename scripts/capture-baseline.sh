#!/usr/bin/env bash
# capture-baseline.sh - snapshot the standard Linux troubleshooting toolkit
sec() { printf '\n\n########## %s ##########\n' "$1"; }
cmd() { printf '\n$ %s\n' "$*"; eval "timeout 20 $*" 2>&1; }

sec "CPU / LOAD"
cmd "nproc"
cmd "lscpu | head -20"
cmd "uptime"
cmd "cat /proc/loadavg"
cmd "vmstat 1 3"
cmd "top -b -n 1 | head -15"
cmd "ps -eo pid,ppid,user,pcpu,pmem,rss,stat,comm --sort=-pcpu | head -10"

sec "MEMORY"
cmd "free -h"
cmd "cat /proc/meminfo | head -12"
cmd "ps -eo pid,user,pmem,rss,comm --sort=-rss | head -8"

sec "DISK CAPACITY (df)"
cmd "df -h"
cmd "df -hT -x tmpfs -x devtmpfs"
cmd "df -i | head -8"

sec "DISK USAGE (du)"
cmd "du -sh /srv/*"
cmd "du -h --max-depth=1 /srv/data | sort -rh"
cmd "du -ah /srv/data | sort -rh | head -8"
cmd "find /srv -xdev -type f -size +1M -exec ls -lh {} + | head -8"

sec "BLOCK DEVICES / MOUNTS"
cmd "losetup -a"
cmd "findmnt -t ext4"
cmd "blkid"
cmd "mount | grep -E 'loop|srv'"

sec "NETWORK - IP"
cmd "ip -brief addr show"
cmd "ip addr show"
cmd "ip route show"
cmd "ip -s link show"
cmd "ip neigh show"

sec "NETWORK - SOCKETS (ss)"
cmd "ss -tulnp"
cmd "ss -tnp state established"
cmd "ss -s"

sec "PROCESSES / SERVICES"
cmd "ps -ef | grep -E 'nginx|sshd' | grep -v grep"
cmd "pgrep -a nginx"
cmd "pgrep -a sshd"

sec "OPEN FILES / LIMITS"
cmd "ulimit -a"
cmd "cat /proc/sys/fs/file-nr"
