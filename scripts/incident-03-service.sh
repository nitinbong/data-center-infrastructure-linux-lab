#!/usr/bin/env bash
# INC-003 - Service outage: web01 nginx will not start after a config change
# Two stacked faults: (a) a typo in the config, (b) a rogue process squatting
# on TCP/80 that was started while nginx was down.
LAB_ROOT="${LAB_ROOT:-$HOME/data-center-lab}"   # override with: LAB_ROOT=/path ./script.sh
sec() { printf '\n########## %s ##########\n' "$1"; }
w() { printf '\n[web01]$ %s\n' "$*"; timeout 20 ip netns exec web01 sh -c "$*" 2>&1; }
CONF=$LAB_ROOT/srv/web01/nginx.conf
ELOG=$LAB_ROOT/srv/web01/logs/error.log

sec "0. PRE-CHECK"
w "curl -s -o /dev/null -w 'HTTP %{http_code}\n' http://10.10.10.11/"
cp "$CONF" "$CONF.bak-$(date +%H%M%S)"
echo "config backed up before change (change-management step)"

sec "1. FAULT INJECTION - maintenance window on web01"
echo "1a. engineer stops nginx to apply a config change"
ip netns exec web01 nginx -s quit -c "$CONF" 2>&1 | sed 's/^/  /'
for i in 1 2 3 4 5 6; do
  ip netns exec web01 ss -tlnH sport = :80 | grep -q . || break
  sleep 1
done
ip netns exec web01 ss -tlnH sport = :80 | grep -q . && echo "  WARNING: port 80 still bound" || echo "  nginx stopped, port 80 released"

echo
echo "1b. a stale deploy helper from a cron job starts up and grabs the now-free port"
ip netns exec web01 python3 -c "
import socket,time,os
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(('10.10.10.11',80)); s.listen(5)
open('/tmp/rogue.pid','w').write(str(os.getpid()))
time.sleep(900)" >/dev/null 2>&1 </dev/null &
sleep 2
echo "  helper pid $(cat /tmp/rogue.pid 2>/dev/null) is now listening on 10.10.10.11:80"

echo
echo "1c. the config edit introduces a typo and points at a doc root that was never created"
sed -i 's/worker_connections/worker_conections/' "$CONF"
sed -i 's#root         /srv/webcontent;#root         /srv/webcontent-v2;#' "$CONF"
grep -n 'conections\|webcontent-v2' "$CONF"

sec "2. SYMPTOM - the site is down"
w "curl -s -m 4 -o /dev/null -w 'HTTP %{http_code}\n' http://10.10.10.11/ ; echo \"curl exit=\$?\""
w "pgrep -a nginx | grep web01 || echo '(no nginx master for web01 - service is stopped)'"
echo
echo "Health check reports the outage:"
timeout 60 ip netns exec web01 bash $LAB_ROOT/monitoring/health-check.sh -q -p 10.10.10.12 -s "sshd" -l "80 22" -u "http://10.10.10.11/ http://10.10.10.11/health" 2>&1 | tail -8

sec "3. TRIAGE"
echo "--- 3a. Try to start it and read the error (systemctl start nginx equivalent) ---"
w "nginx -c $CONF >/tmp/ngstart.log 2>&1 </dev/null; echo \"start exit=\$?\"; cat /tmp/ngstart.log"
echo
echo "--- 3b. Validate the configuration file (always do this first) ---"
w "nginx -t -c $CONF"
echo "FINDING 1: unknown directive 'worker_conections' at line 5 - typo in the change."

sed -i 's/worker_conections/worker_connections/' "$CONF"
echo
echo "--- 3c. Typo corrected, validate again and retry the start ---"
w "nginx -t -c $CONF"
w "nginx -c $CONF >/tmp/ngstart.log 2>&1 </dev/null; echo \"start exit=\$?\"; cat /tmp/ngstart.log"
echo "FINDING 2: bind() to 10.10.10.11:80 failed (98: Address already in use)."
echo
echo "--- 3d. Who owns port 80? ---"
w "ss -tlnp sport = :80"
w "ss -tlnp | grep ':80 '"
RPID=$(cat /tmp/rogue.pid 2>/dev/null); [ -z "$RPID" ] && RPID=1
echo
echo "--- 3e. Identify the squatting process before killing anything ---"
w "ps -o pid,ppid,user,etime,cmd -p $RPID"
w "ls -l /proc/$RPID/cwd /proc/$RPID/exe 2>/dev/null | head -3"
echo
echo "--- 3f. Recent error log ---"
w "tail -6 $ELOG"

sec "4. FIX"
echo "4a. terminate the rogue listener that is holding TCP/80"
kill "$RPID" 2>/dev/null; sleep 1
w "ss -tlnp sport = :80 || echo '(port 80 now free)'"
echo
echo "4b. start nginx"
w "nginx -c $CONF >/tmp/ngstart.log 2>&1 </dev/null; echo \"start exit=\$?\"; cat /tmp/ngstart.log"
sleep 1
w "pgrep -a nginx | grep web01"
echo
echo "4c. site now answers - but with the wrong document root"
w "curl -s -m 4 -o /dev/null -w 'HTTP %{http_code}\n' http://10.10.10.11/"
w "tail -2 $ELOG"
echo "FINDING 3: root points at /srv/webcontent-v2 which does not exist -> 404."
w "ls -ld /srv/webcontent-v2 2>&1 || true"
echo
echo "4d. restore the correct document root and reload"
sed -i 's#root         /srv/webcontent-v2;#root         /srv/webcontent;#' "$CONF"
w "nginx -t -c $CONF"
w "nginx -s reload -c $CONF"
sleep 1

sec "5. VERIFY"
w "curl -s -o /dev/null -w 'HTTP %{http_code} in %{time_total}s\n' http://10.10.10.11/"
w "curl -s http://10.10.10.11/health"
w "curl -s http://10.10.10.11/ | head -2"
w "ss -tlnp sport = :80"
timeout 60 ip netns exec web01 bash $LAB_ROOT/monitoring/health-check.sh -q -p 10.10.10.12 -s "sshd" -l "80 22" -u "http://10.10.10.11/ http://10.10.10.11/health" 2>&1 | tail -5
echo
echo "SERVICE RESTORED"
pkill -f "time.sleep(900)" 2>/dev/null; rm -f /tmp/rogue.pid
