#!/usr/bin/env bash
# INC-001 - Network outage: app01 unreachable from web01
# Fault injected: app01's interface is reconfigured onto the wrong subnet
# (10.10.20.12/24 instead of 10.10.10.12/24) during a "cleanup".
sec() { printf '\n########## %s ##########\n' "$1"; }
w() { printf '\n[web01]$ %s\n' "$*"; timeout 20 ip netns exec web01 sh -c "$*" 2>&1; }
wu() { printf '\n[web01 as sysadmin]$ %s\n' "$*"; timeout 20 ip netns exec web01 su - sysadmin -c "$*" 2>&1; }
a() { printf '\n[app01]$ %s\n' "$*"; timeout 20 ip netns exec app01 sh -c "$*" 2>&1; }

sec "0. PRE-CHECK - service is healthy"
w "ping -c 2 -W 2 10.10.10.12 | tail -2"
w "curl -s -m 3 http://10.10.10.12:8080/health"

sec "1. FAULT INJECTION (change window: interface re-addressed)"
ip netns exec app01 ip addr del 10.10.10.12/24 dev veth-app
ip netns exec app01 ip addr add 10.10.20.12/24 dev veth-app
echo "app01 interface re-addressed to 10.10.20.12/24"

sec "2. SYMPTOM - what the monitoring and the users see"
w "ping -c 3 -W 2 10.10.10.12; echo \"ping exit=\$?\""
w "curl -s -m 4 -o /dev/null -w 'http_code=%{http_code}\n' http://10.10.10.12:8080/health; echo \"curl exit=\$?\""
wu "timeout 8 ssh -o BatchMode=yes -o ConnectTimeout=4 10.10.10.12 hostname; echo \"ssh exit=\$?\""

sec "3. TRIAGE - work up the stack: link -> address -> route -> ARP -> socket"
echo "--- Layer 1/2: is the link up on our side? ---"
w "ip -brief link show veth-web"
w "ip -s link show veth-web | tail -4"
echo
echo "--- Layer 3: our own address and route ---"
w "ip -brief addr show"
w "ip route get 10.10.10.12"
echo
echo "--- Layer 2 resolution: does the peer answer ARP? ---"
w "ip neigh flush all; ping -c1 -W2 10.10.10.12 >/dev/null 2>&1; ip neigh show"
echo "NOTE: state FAILED / INCOMPLETE for 10.10.10.12 means no host on this L2"
echo "      segment owns that IP any more - the peer's address changed."
echo
echo "--- Confirm from the peer side ---"
a "ip -brief addr show"
a "ip route show"
a "ss -tlnp"
echo
echo "ROOT CAUSE: app01 holds 10.10.20.12/24. web01 (10.10.10.11/24) has no"
echo "route to 10.10.20.0/24, and nothing on the link answers for 10.10.10.12."
echo "Services on app01 never stopped - ss still shows both listeners bound."

sec "4. FIX - restore the documented static address"
ip netns exec app01 ip addr del 10.10.20.12/24 dev veth-app
ip netns exec app01 ip addr add 10.10.10.12/24 dev veth-app
echo "restored 10.10.10.12/24 on app01"
ip netns exec web01 ip neigh flush all
a "ip -brief addr show"

sec "5. VERIFY - full service restoration"
w "ping -c 3 -W 2 10.10.10.12 | tail -3"
w "ip neigh show"
w "curl -s -m 4 http://10.10.10.12:8080/health"
wu "timeout 8 ssh -o BatchMode=yes -o ConnectTimeout=4 10.10.10.12 'echo SSH restored'"
echo
echo "SERVICE RESTORED"
