#!/usr/bin/env bash
# service-lifecycle.sh - full start/stop/reload/status cycle for nginx on web01
# Each step is annotated with the equivalent systemd command for a real VM.
LAB_ROOT="${LAB_ROOT:-$HOME/data-center-lab}"   # override with: LAB_ROOT=/path ./script.sh
CONF=$LAB_ROOT/srv/web01/nginx.conf
PIDF=/run/nginx-web01.pid
sec() { printf '\n----------------------------------------------------------\n%s\n----------------------------------------------------------\n' "$1"; }
cmd() { printf '\n$ %s\n' "$*"; eval "timeout 15 $*" 2>&1; }

sec "1. STATUS   (systemd equivalent: systemctl status nginx)"
cmd "pgrep -a nginx"
cmd "cat $PIDF"
cmd "ss -tlnp sport = :80"
cmd "curl -s -o /dev/null -w 'HTTP %{http_code} in %{time_total}s\n' http://10.10.10.11/"

sec "2. CONFIG VALIDATION   (nginx -t : always run before reload)"
cmd "nginx -t -c $CONF"

sec "3. RELOAD - zero downtime, workers replaced   (systemctl reload nginx)"
echo "worker PIDs before reload:"; pgrep -x nginx | tr '\n' ' '; echo
cmd "nginx -s reload -c $CONF"
sleep 1
echo "worker PIDs after reload:"; pgrep -x nginx | tr '\n' ' '; echo
cmd "curl -s http://10.10.10.11/health"

sec "4. STOP   (systemctl stop nginx)"
cmd "nginx -s quit -c $CONF"
sleep 1
cmd "pgrep -a nginx || echo '(no nginx processes - service stopped)'"
cmd "ss -tlnp sport = :80 || true"
cmd "curl -s -m 4 http://10.10.10.11/ ; echo \"curl exit=\$? (7 = connection refused, nothing listening)\""

sec "5. START   (systemctl start nginx)"
cmd "nginx -c $CONF"
sleep 1
cmd "pgrep -a nginx"
cmd "curl -s -o /dev/null -w 'HTTP %{http_code}\n' http://10.10.10.11/"

sec "6. LOGS   (journalctl -u nginx  /  tail of the access + error logs)"
cmd "tail -5 $LAB_ROOT/srv/web01/logs/access.log"
cmd "tail -5 $LAB_ROOT/srv/web01/logs/error.log || echo '(error log empty - healthy)'"
