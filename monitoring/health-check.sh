#!/usr/bin/env bash
#===============================================================================
# health-check.sh - Data Center Ops Home Lab
#
# Single-pass health check for a Linux server. Checks CPU load, memory, swap,
# disk capacity, inodes, required services, listening ports and peer
# reachability, then prints a coloured report and exits with a Nagios-style
# status code so it can be dropped straight into cron or a monitoring agent.
#
# Usage:
#   ./health-check.sh [-q] [-j] [-p PEER_IP] [-s "svc1 svc2"] [-w N] [-c N]
#     -q         quiet: only print WARN/CRIT lines
#     -j         emit JSON instead of the human report
#     -p PEER    peer IP to ping-test (default 10.10.10.12)
#     -s "LIST"  space separated process names that must be running
#     -l "LIST"  space separated TCP ports that must have a listener
#     -u "LIST"  space separated URLs that must answer 2xx/3xx
#     -w N       disk warning threshold  %% (default 80)
#     -c N       disk critical threshold %% (default 90)
#
# Exit codes: 0 = OK, 1 = WARNING, 2 = CRITICAL
#
# Author: Data Center Infrastructure & Linux Operations Home Lab
#===============================================================================
set -o pipefail

#--- defaults ------------------------------------------------------------------
QUIET=0
JSON=0
PEER="10.10.10.12"
SERVICES="nginx sshd"
REQ_PORTS="22"
CHECK_URLS=""
DISK_WARN=80
DISK_CRIT=90
MEM_WARN=80
MEM_CRIT=90
LOAD_WARN_PER_CPU=1.0
LOAD_CRIT_PER_CPU=2.0

while getopts "qjp:s:l:u:w:c:h" opt; do
  case $opt in
    q) QUIET=1 ;;
    j) JSON=1 ;;
    p) PEER="$OPTARG" ;;
    s) SERVICES="$OPTARG" ;;
    l) REQ_PORTS="$OPTARG" ;;
    u) CHECK_URLS="$OPTARG" ;;
    w) DISK_WARN="$OPTARG" ;;
    c) DISK_CRIT="$OPTARG" ;;
    h) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "invalid option; try -h" >&2; exit 3 ;;
  esac
done

#--- state ---------------------------------------------------------------------
EXIT=0
declare -a PROBLEMS=()
declare -a JSON_ROWS=()

if [ -t 1 ] && [ "$JSON" -eq 0 ]; then
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_CRIT=$'\033[31m'; C_OFF=$'\033[0m'; C_HDR=$'\033[1;36m'
else
  C_OK=""; C_WARN=""; C_CRIT=""; C_OFF=""; C_HDR=""
fi

# escalate() STATUS MESSAGE
escalate() {
  case "$1" in
    WARN) [ "$EXIT" -lt 1 ] && EXIT=1 ;;
    CRIT) EXIT=2 ;;
  esac
  [ "$1" != "OK" ] && PROBLEMS+=("[$1] $2")
}

# report() STATUS CHECKNAME DETAIL VALUE
report() {
  local status="$1" name="$2" detail="$3" value="${4:-}"
  escalate "$status" "$name: $detail"
  JSON_ROWS+=("{\"check\":\"$name\",\"status\":\"$status\",\"value\":\"$value\",\"detail\":\"$detail\"}")
  [ "$JSON" -eq 1 ] && return
  [ "$QUIET" -eq 1 ] && [ "$status" = "OK" ] && return
  local colour="$C_OK"
  [ "$status" = "WARN" ] && colour="$C_WARN"
  [ "$status" = "CRIT" ] && colour="$C_CRIT"
  printf '  %s%-4s%s  %-22s %s\n' "$colour" "$status" "$C_OFF" "$name" "$detail"
}

header() { [ "$JSON" -eq 0 ] && [ "$QUIET" -eq 0 ] && printf '\n%s%s%s\n' "$C_HDR" "$1" "$C_OFF"; }

#--- 0. Host facts -------------------------------------------------------------
HOSTNAME_S=$(hostname)
KERNEL=$(uname -r)
UPTIME_S=$(uptime -p 2>/dev/null || uptime)
NCPU=$(nproc)
PRIMARY_IP=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
[ -z "$PRIMARY_IP" ] && PRIMARY_IP="n/a"

if [ "$JSON" -eq 0 ] && [ "$QUIET" -eq 0 ]; then
  echo "==============================================================="
  echo " SERVER HEALTH REPORT   $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "==============================================================="
  printf ' Host    : %s (%s)\n' "$HOSTNAME_S" "$PRIMARY_IP"
  printf ' Kernel  : %s   CPUs: %s\n' "$KERNEL" "$NCPU"
  printf ' Uptime  : %s\n' "$UPTIME_S"
fi

#--- 1. CPU load ---------------------------------------------------------------
header "CPU"
read -r L1 L5 L15 _ < /proc/loadavg
LOAD_PER_CPU=$(awk -v l="$L1" -v n="$NCPU" 'BEGIN{printf "%.2f", l/n}')
CRIT_T=$(awk -v n="$NCPU" -v t="$LOAD_CRIT_PER_CPU" 'BEGIN{printf "%.2f", n*t}')
WARN_T=$(awk -v n="$NCPU" -v t="$LOAD_WARN_PER_CPU" 'BEGIN{printf "%.2f", n*t}')
if awk -v a="$L1" -v b="$CRIT_T" 'BEGIN{exit !(a>b)}'; then
  report CRIT "load-average" "1m load $L1 over crit threshold $CRIT_T (${LOAD_PER_CPU}/core)" "$L1"
elif awk -v a="$L1" -v b="$WARN_T" 'BEGIN{exit !(a>b)}'; then
  report WARN "load-average" "1m load $L1 over warn threshold $WARN_T (${LOAD_PER_CPU}/core)" "$L1"
else
  report OK "load-average" "1/5/15m = $L1 / $L5 / $L15 (${LOAD_PER_CPU} per core)" "$L1"
fi

# %idle sampled from /proc/stat over 1 second
read -r _ u1 n1 s1 i1 w1 irq1 sirq1 _ < /proc/stat
sleep 1
read -r _ u2 n2 s2 i2 w2 irq2 sirq2 _ < /proc/stat
TOT=$(( (u2+n2+s2+i2+w2+irq2+sirq2) - (u1+n1+s1+i1+w1+irq1+sirq1) ))
IDLE=$(( i2 - i1 ))
if [ "$TOT" -gt 0 ]; then
  CPU_USED=$(awk -v t="$TOT" -v i="$IDLE" 'BEGIN{printf "%.1f", 100*(t-i)/t}')
  if awk -v a="$CPU_USED" 'BEGIN{exit !(a>90)}'; then
    report CRIT "cpu-utilisation" "${CPU_USED}% busy" "$CPU_USED"
  elif awk -v a="$CPU_USED" 'BEGIN{exit !(a>80)}'; then
    report WARN "cpu-utilisation" "${CPU_USED}% busy" "$CPU_USED"
  else
    report OK "cpu-utilisation" "${CPU_USED}% busy over 1s sample" "$CPU_USED"
  fi
fi

#--- 2. Memory & swap ----------------------------------------------------------
header "MEMORY"
MEM_TOTAL=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
MEM_AVAIL=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
SWAP_TOTAL=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo)
SWAP_FREE=$(awk '/^SwapFree:/{print $2}' /proc/meminfo)
MEM_PCT=$(awk -v t="$MEM_TOTAL" -v a="$MEM_AVAIL" 'BEGIN{printf "%.1f", 100*(t-a)/t}')
MEM_H=$(awk -v t="$MEM_TOTAL" -v a="$MEM_AVAIL" 'BEGIN{printf "%.1fG used of %.1fG", (t-a)/1048576, t/1048576}')
if awk -v a="$MEM_PCT" -v c="$MEM_CRIT" 'BEGIN{exit !(a>c)}'; then
  report CRIT "memory" "$MEM_H (${MEM_PCT}%)" "$MEM_PCT"
elif awk -v a="$MEM_PCT" -v w="$MEM_WARN" 'BEGIN{exit !(a>w)}'; then
  report WARN "memory" "$MEM_H (${MEM_PCT}%)" "$MEM_PCT"
else
  report OK "memory" "$MEM_H (${MEM_PCT}%)" "$MEM_PCT"
fi
if [ "${SWAP_TOTAL:-0}" -gt 0 ]; then
  SWAP_PCT=$(awk -v t="$SWAP_TOTAL" -v f="$SWAP_FREE" 'BEGIN{printf "%.1f", 100*(t-f)/t}')
  if awk -v a="$SWAP_PCT" 'BEGIN{exit !(a>50)}'; then
    report WARN "swap" "${SWAP_PCT}% of swap in use - memory pressure" "$SWAP_PCT"
  else
    report OK "swap" "${SWAP_PCT}% in use" "$SWAP_PCT"
  fi
else
  report OK "swap" "no swap configured" "0"
fi

# Top 3 memory consumers (informational)
if [ "$JSON" -eq 0 ] && [ "$QUIET" -eq 0 ]; then
  echo "  ---- top memory consumers ----"
  ps -eo pmem,rss,comm --sort=-pmem 2>/dev/null | head -4 | sed 's/^/       /'
fi

#--- 3. Disk capacity & inodes -------------------------------------------------
header "STORAGE"
while read -r fs size used avail pct mnt; do
  case "$fs" in /dev/*) ;; *) continue ;; esac    # real block devices only
  n=${pct%\%}
  if [ "$n" -ge "$DISK_CRIT" ]; then
    report CRIT "disk:$mnt" "${pct} used (${avail} free of ${size}) on $fs" "$n"
  elif [ "$n" -ge "$DISK_WARN" ]; then
    report WARN "disk:$mnt" "${pct} used (${avail} free of ${size}) on $fs" "$n"
  else
    report OK "disk:$mnt" "${pct} used (${avail} free of ${size})" "$n"
  fi
done < <(df -hP -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | tail -n +2)

while read -r fs inodes iused ifree ipct mnt; do
  case "$fs" in /dev/*) ;; *) continue ;; esac
  n=${ipct%\%}
  case "$n" in ''|*[!0-9]*) continue ;; esac
  if [ "$n" -ge "$DISK_CRIT" ]; then
    report CRIT "inodes:$mnt" "${ipct} of inodes used ($ifree free)" "$n"
  elif [ "$n" -ge "$DISK_WARN" ]; then
    report WARN "inodes:$mnt" "${ipct} of inodes used ($ifree free)" "$n"
  fi
done < <(df -iP -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | tail -n +2)

# Read-only mounts are a classic silent outage
RO=$(findmnt -rn -o TARGET,OPTIONS 2>/dev/null | awk '$2 ~ /(^|,)ro(,|$)/ {print $1}' \
     | grep -vE '^/(snap|sys|proc|mnt|opt|usr/lib/modules)' | tr '\n' ' ')
if [ -n "$RO" ]; then
  report WARN "mount-readonly" "read-only mounts detected: $RO" "$RO"
else
  report OK "mount-readonly" "no unexpected read-only mounts" "none"
fi

#--- 4. Services ---------------------------------------------------------------
header "SERVICES"
for svc in $SERVICES; do
  if command -v systemctl >/dev/null 2>&1 && systemctl is-system-running >/dev/null 2>&1; then
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      since=$(systemctl show -p ActiveEnterTimestamp --value "$svc" 2>/dev/null)
      report OK "service:$svc" "active (since ${since:-unknown})" "active"
    else
      report CRIT "service:$svc" "NOT active - check 'systemctl status $svc'" "inactive"
    fi
  else
    # Fallback for hosts without a running systemd (containers, netns labs)
    if pgrep -x "$svc" >/dev/null 2>&1; then
      cnt=$(pgrep -x "$svc" | wc -l)
      report OK "service:$svc" "$cnt process(es) running (pgrep)" "running"
    else
      report CRIT "service:$svc" "no running process found" "stopped"
    fi
  fi
done

#--- 5. Listening ports --------------------------------------------------------
header "NETWORK"
PORTS=$(ss -tlnH 2>/dev/null | awk '{print $4}' | sed 's/.*://' | sort -un | tr '\n' ' ')
if [ -n "$PORTS" ]; then
  report OK "listening-ports" "TCP listeners: $PORTS" "$PORTS"
else
  report WARN "listening-ports" "no TCP listeners found" "none"
fi
for p in $REQ_PORTS; do
  if ss -tlnH "sport = :$p" 2>/dev/null | grep -q .; then
    report OK "port:$p" "listener present on TCP/$p" "listening"
  else
    report CRIT "port:$p" "NO listener on TCP/$p - service is down" "missing"
  fi
done

for u in $CHECK_URLS; do
  code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$u" 2>/dev/null)
  case "$code" in
    2*|3*) report OK   "http:$u" "responded HTTP $code" "$code" ;;
    000)   report CRIT "http:$u" "no HTTP response (connect failed or timed out)" "000" ;;
    *)     report CRIT "http:$u" "responded HTTP $code" "$code" ;;
  esac
done

ESTAB=$(ss -tnH state established 2>/dev/null | wc -l)
report OK "established-conns" "$ESTAB established TCP connections" "$ESTAB"

#--- 6. Peer reachability ------------------------------------------------------
if [ -n "$PEER" ]; then
  if ping -c 2 -W 2 "$PEER" >/dev/null 2>&1; then
    RTT=$(ping -c 3 -W 2 "$PEER" 2>/dev/null | awk -F'/' '/^rtt|^round-trip/{printf "%.3f", $5}')
    report OK "peer:$PEER" "reachable, avg rtt ${RTT:-?} ms" "up"
  else
    report CRIT "peer:$PEER" "ICMP unreachable - check link, route, firewall" "down"
  fi
fi

#--- 7. Security spot checks ---------------------------------------------------
header "SECURITY"
if [ -r /etc/shadow ]; then
  NOPASS=$(awk -F: '($2==""){print $1}' /etc/shadow | tr '\n' ' ')
  if [ -n "$NOPASS" ]; then
    report CRIT "empty-passwords" "accounts with no password: $NOPASS" "$NOPASS"
  else
    report OK "empty-passwords" "no accounts with empty passwords" "none"
  fi
fi
UID0=$(awk -F: '($3==0){print $1}' /etc/passwd | grep -v '^root$' | tr '\n' ' ')
if [ -n "$UID0" ]; then
  report CRIT "uid0-accounts" "non-root accounts with UID 0: $UID0" "$UID0"
else
  report OK "uid0-accounts" "root is the only UID 0 account" "root"
fi
WW=$(find /etc -xdev -type f -perm -o+w 2>/dev/null | head -5 | tr '\n' ' ')
if [ -n "$WW" ]; then
  report WARN "world-writable-etc" "world-writable files under /etc: $WW" "$WW"
else
  report OK "world-writable-etc" "no world-writable files under /etc" "none"
fi

#--- Output --------------------------------------------------------------------
if [ "$JSON" -eq 1 ]; then
  printf '{"host":"%s","ip":"%s","timestamp":"%s","exit_code":%d,"overall":"%s","checks":[' \
    "$HOSTNAME_S" "$PRIMARY_IP" "$(date -Is)" "$EXIT" \
    "$([ $EXIT -eq 0 ] && echo OK || { [ $EXIT -eq 1 ] && echo WARNING || echo CRITICAL; })"
  printf '%s' "$(IFS=,; echo "${JSON_ROWS[*]}")"
  printf ']}\n'
  exit $EXIT
fi

echo
echo "==============================================================="
case $EXIT in
  0) printf ' OVERALL: %sOK%s - all checks passed\n' "$C_OK" "$C_OFF" ;;
  1) printf ' OVERALL: %sWARNING%s - %d issue(s)\n' "$C_WARN" "$C_OFF" "${#PROBLEMS[@]}" ;;
  2) printf ' OVERALL: %sCRITICAL%s - %d issue(s)\n' "$C_CRIT" "$C_OFF" "${#PROBLEMS[@]}" ;;
esac
for p in "${PROBLEMS[@]}"; do echo "   - $p"; done
echo "==============================================================="
exit $EXIT
