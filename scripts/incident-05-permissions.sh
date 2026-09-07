#!/usr/bin/env bash
# INC-005 - nginx returns 403 Forbidden after a permissions change on the doc root,
# and a content editor loses write access to a shared file.
LAB_ROOT="${LAB_ROOT:-$HOME/data-center-lab}"   # override with: LAB_ROOT=/path ./script.sh
sec() { printf '\n########## %s ##########\n' "$1"; }
w() { printf '\n[web01]$ %s\n' "$*"; timeout 25 ip netns exec web01 sh -c "$*" 2>&1; }
DOC=/srv/webcontent
ELOG=$LAB_ROOT/srv/web01/logs/error.log

sec "0. PRE-CHECK - site healthy"
w "curl -s -o /dev/null -w 'HTTP %{http_code}\n' http://10.10.10.11/"
w "ls -ld $DOC; ls -l $DOC/index.html"

sec "1. FAULT INJECTION"
echo "1a. an admin 'hardens' the document root by locking it down to its owner"
chmod 700 "$DOC"
chown root:root "$DOC"
ls -ld "$DOC"
echo
echo "1b. a page is published by deploy with a restrictive umask"
echo '<h1>maintenance notice</h1>' > "$DOC/notice.html"
chown deploy:deploy "$DOC/notice.html"
chmod 640 "$DOC/notice.html"
ls -l "$DOC/notice.html"

sec "2. SYMPTOM"
w "curl -s -o /dev/null -w 'HTTP %{http_code}\n' http://10.10.10.11/"
w "curl -s http://10.10.10.11/ | head -3"
echo
echo "Health check:"
timeout 60 ip netns exec web01 bash $LAB_ROOT/monitoring/health-check.sh -q -p 10.10.10.12 \
  -s sshd -l "80 22" -u "http://10.10.10.11/" 2>&1 | tail -7
echo
echo "Content editor webdev also reports she can no longer edit the notice page:"
w "su webdev -c \"echo '<h1>updated</h1>' > $DOC/notice.html\"; echo \"exit=\$?\""

sec "3. TRIAGE - part A: the 403"
echo "--- 3a. The service is running, so this is not an outage ---"
w "ss -tlnp sport = :80"
w "pgrep -a nginx | grep web01"
echo "A 403 means nginx answered. The request reached the server and was refused,"
echo "so this is authorisation, not availability."
echo
echo "--- 3b. The error log names the exact file and the exact errno ---"
w "tail -3 $ELOG"
echo
echo "--- 3c. Which user does the worker actually run as? ---"
w "ps -o pid,user,cmd -C nginx | head -4"
w "grep -m1 '^user' $LAB_ROOT/srv/web01/nginx.conf"
w "id www-data"
echo "The master runs as root to bind port 80; the WORKERS drop to www-data and"
echo "they are the ones that open files. Permissions must satisfy www-data."
echo
echo "--- 3d. Reproduce the failure as that user - do not guess ---"
w "su -s /bin/sh www-data -c \"ls $DOC\"; echo \"exit=\$?\""
w "su -s /bin/sh www-data -c \"cat $DOC/index.html >/dev/null\"; echo \"exit=\$?\""
echo
echo "--- 3e. Walk every component of the path ---"
if command -v namei >/dev/null 2>&1; then
  w "namei -l $DOC/index.html"
else
  w "stat -c '%A %U:%G %n' / /srv $DOC $DOC/index.html"
fi
echo "FINDING: $DOC is 0700 root:root. www-data is neither the owner nor in the"
echo "group, so 'other' applies and other has no permissions at all - it cannot"
echo "even traverse (x) into the directory, let alone read (r) the file."

sec "4. TRIAGE - part B: the editor who cannot write"
w "ls -l $DOC/notice.html"
w "id webdev"
echo "FINDING: notice.html is 0640 deploy:deploy. webdev is in 'webadmins', not"
echo "in 'deploy', so again only 'other' applies - and other has no write bit."
echo "The file was created without the shared group because it was chowned away"
echo "from the SGID-inherited group."

sec "5. FIX"
echo "5a. restore the document root to the documented state"
chown root:webadmins "$DOC"
chmod 2775 "$DOC"            # rwxrwsr-x : owner+group write, world traverse+read, SGID
w "ls -ld $DOC"
echo
echo "5b. put the published file back under the shared group"
chown deploy:webadmins "$DOC/notice.html"
chmod 664 "$DOC/notice.html"
w "ls -l $DOC/notice.html"
echo
echo "NOT the fix: chmod -R 777 $DOC"
echo "That would let every local account - including unprivileged service"
echo "accounts - rewrite the served content, which turns a 403 into a defacement"
echo "vector. The correct fix is group membership plus the SGID bit."

sec "6. VERIFY"
w "curl -s -o /dev/null -w 'HTTP %{http_code}\n' http://10.10.10.11/"
w "curl -s http://10.10.10.11/ | head -2"
w "curl -s -o /dev/null -w 'notice.html HTTP %{http_code}\n' http://10.10.10.11/notice.html"
w "su -s /bin/sh www-data -c \"cat $DOC/index.html >/dev/null\"; echo \"www-data read exit=\$?\""
w "su webdev -c \"echo '<h1>updated by webdev</h1>' > $DOC/notice.html\"; echo \"webdev write exit=\$?\""
w "ls -l $DOC/notice.html; cat $DOC/notice.html"
echo
echo "--- SGID still working: a new file inherits the shared group ---"
w "su webdev -c \"touch $DOC/verify-sgid.html\"; ls -l $DOC/verify-sgid.html"
w "getfacl $DOC 2>/dev/null | head -8"
timeout 60 ip netns exec web01 bash $LAB_ROOT/monitoring/health-check.sh -q -p 10.10.10.12 \
  -s sshd -l "80 22" -u "http://10.10.10.11/" 2>&1 | tail -4
echo
echo "SERVICE RESTORED"
rm -f "$DOC/verify-sgid.html"
