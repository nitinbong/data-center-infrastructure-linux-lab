#!/usr/bin/env bash
# INC-002 - SSH key authentication fails to app01 after a home-directory restore
# Fault injected: ~/.ssh and authorized_keys restored with group/world-writable
# permissions, which sshd StrictModes rejects.
LAB_ROOT="${LAB_ROOT:-$HOME/data-center-lab}"   # override with: LAB_ROOT=/path ./script.sh
sec() { printf '\n########## %s ##########\n' "$1"; }
wu() { printf '\n[web01 as sysadmin]$ %s\n' "$*"; timeout 25 ip netns exec web01 su - sysadmin -c "$*" 2>&1; }
r()  { printf '\n[app01 as root]$ %s\n' "$*"; timeout 25 sh -c "$*" 2>&1; }
LOG=$LAB_ROOT/srv/app01/sshd.log

sec "0. PRE-CHECK - key based login works"
wu "ssh -o BatchMode=yes -o ConnectTimeout=4 10.10.10.12 'echo login OK as \$(whoami)'"
r "ls -ld /home/sysadmin /home/sysadmin/.ssh /home/sysadmin/.ssh/authorized_keys"

MARK=$(wc -l < "$LOG")

sec "1. FAULT INJECTION (home directory restored from backup with bad modes)"
chmod 777 /home/sysadmin/.ssh
chmod 666 /home/sysadmin/.ssh/authorized_keys
chmod 775 /home/sysadmin
echo "permissions after 'restore':"
ls -ld /home/sysadmin /home/sysadmin/.ssh /home/sysadmin/.ssh/authorized_keys

sec "2. SYMPTOM - automation and admins are locked out"
wu "ssh -o BatchMode=yes -o ConnectTimeout=5 10.10.10.12 hostname; echo \"ssh exit=\$?\""
echo "(The Python fleet monitor collects app01 over this same SSH path, so it"
echo " would now report app01 as UNKNOWN / collection failed.)"

sec "3. TRIAGE"
echo "--- 3a. Is this a network problem or an auth problem? ---"
wu "ping -c 2 -W 2 10.10.10.12 | tail -2"
wu "nc -z -w 3 10.10.10.12 22 2>/dev/null && echo 'TCP 22 open' || timeout 4 sh -c 'echo > /dev/tcp/10.10.10.12/22' && echo 'TCP 22 open - transport fine, so this is authentication'"
echo
echo "--- 3b. Verbose client output: which key is offered, what does the server say? ---"
wu "ssh -vv -o BatchMode=yes -o ConnectTimeout=5 10.10.10.12 hostname 2>&1 | grep -Ei 'offering|Authentications that can continue|Permission denied|publickey|debug1: Next authentication' | head -8"
echo
echo "--- 3c. Server side is authoritative: read the sshd log ---"
r "tail -n +$MARK $LOG | grep -Ei 'authentication refused|bad ownership|Failed|Connection closed' | head -6"
echo
echo "--- 3d. Confirm the effective sshd policy ---"
r "/usr/sbin/sshd -T -f $LAB_ROOT/srv/app01/sshd_config | grep -Ei '^(strictmodes|pubkeyauthentication|authorizedkeysfile|allowgroups|permitrootlogin)'"
r "ls -ld /home/sysadmin /home/sysadmin/.ssh /home/sysadmin/.ssh/authorized_keys"
r "id sysadmin"
echo
echo "ROOT CAUSE: sshd runs with StrictModes=yes. It refuses to trust an"
echo "authorized_keys file that is writable by anyone other than the owner,"
echo "because another user could append their own key and impersonate this"
echo "account. .ssh was 0777 and authorized_keys was 0666, so the key was"
echo "ignored and the only remaining method was password auth, which the"
echo "automation (BatchMode=yes) cannot use."

sec "4. FIX - restore the required ownership and modes"
chown -R sysadmin:sysadmin /home/sysadmin
chmod 750 /home/sysadmin
chmod 700 /home/sysadmin/.ssh
chmod 600 /home/sysadmin/.ssh/authorized_keys
chmod 600 /home/sysadmin/.ssh/id_ed25519
chmod 644 /home/sysadmin/.ssh/id_ed25519.pub
r "ls -ld /home/sysadmin /home/sysadmin/.ssh; ls -l /home/sysadmin/.ssh/"

sec "5. VERIFY"
wu "ssh -o BatchMode=yes -o ConnectTimeout=5 10.10.10.12 'echo login OK as \$(whoami) from \$SSH_CLIENT'"
r "tail -3 $LOG | grep -i accepted"
echo
echo "--- monitoring path restored ---"
timeout 90 ip netns exec web01 su sysadmin -c "python3 $LAB_ROOT/monitoring/fleet-monitor.py --quiet --no-colour" 2>&1 | tail -12
echo
echo "SERVICE RESTORED"
