#!/usr/bin/env bash
#===============================================================================
# lab-build.sh - Data Center Infrastructure & Linux Operations Home Lab
#
# Builds the entire two-node lab from scratch on a single Ubuntu 24.04 host.
# The two "servers" are Linux network namespaces joined by a veth pair, so each
# has its own network stack, its own IP, its own sshd and its own nginx.
#
# Run as root:   sudo bash lab-build.sh
# Tear down:     sudo bash lab-build.sh --destroy
#
# On real VMs, skip the namespace section and apply the same addressing via
# netplan; every other step is identical.
#===============================================================================
LAB_ROOT="${LAB_ROOT:-$HOME/data-center-lab}"   # override with: LAB_ROOT=/path ./script.sh
set -u
LAB="$LAB_ROOT"
WEB_IP=10.10.10.11
APP_IP=10.10.10.12

destroy() {
  echo "tearing down..."
  pkill -f "$LAB/srv/web01/nginx.conf" 2>/dev/null
  pkill -f "$LAB/srv/app01/nginx.conf" 2>/dev/null
  pkill -f "sshd-web01" 2>/dev/null
  for pid in /run/sshd-web01.pid /run/sshd-app01.pid; do
    [ -f "$pid" ] && kill "$(cat "$pid")" 2>/dev/null
  done
  umount /srv/data /srv/mirror/primary /srv/mirror/secondary 2>/dev/null
  for img in "$LAB"/disks/*.img; do
    L=$(losetup -j "$img" 2>/dev/null | cut -d: -f1)
    [ -n "$L" ] && losetup -d "$L"
  done
  ip netns del web01 2>/dev/null
  ip netns del app01 2>/dev/null
  echo "done"
  exit 0
}
[ "${1:-}" = "--destroy" ] && destroy

echo "### 1. packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq iproute2 iputils-ping net-tools openssh-server openssh-client \
    nginx mdadm acl sudo ufw iptables rsync curl bc sysstat tree

echo "### 2. network namespaces = the two servers"
ip netns del web01 2>/dev/null; ip netns del app01 2>/dev/null
ip netns add web01
ip netns add app01
ip link add veth-web type veth peer name veth-app
ip link set veth-web netns web01
ip link set veth-app netns app01
ip netns exec web01 ip addr add $WEB_IP/24 dev veth-web
ip netns exec app01 ip addr add $APP_IP/24 dev veth-app
ip netns exec web01 ip link set veth-web up
ip netns exec app01 ip link set veth-app up
ip netns exec web01 ip link set lo up
ip netns exec app01 ip link set lo up
ip netns exec web01 ping -c 2 $APP_IP

echo "### 3. users and groups"
groupadd -f webadmins; groupadd -f devops; groupadd -f appteam
for u in sysadmin deploy webdev junior; do
  id "$u" >/dev/null 2>&1 || useradd -m -s /bin/bash "$u"
done
usermod -aG sudo,devops sysadmin
usermod -aG devops,webadmins deploy
usermod -aG webadmins webdev
usermod -aG appteam junior

echo "### 4. permissions, SGID, sticky bit, ACLs"
mkdir -p /srv/webcontent /srv/appcontent /srv/dropbox /srv/secrets
chown root:webadmins /srv/webcontent
chmod 2775 /srv/webcontent                        # SGID: inherit group
setfacl -m g:devops:rwx /srv/webcontent
setfacl -d -m g:webadmins:rwx /srv/webcontent     # default ACL for new files
chmod 1777 /srv/dropbox                           # sticky bit
chown sysadmin:sysadmin /srv/secrets; chmod 700 /srv/secrets
echo "db_password=changeme" > /srv/secrets/app.env
chown sysadmin:sysadmin /srv/secrets/app.env; chmod 600 /srv/secrets/app.env

echo "### 5. storage: loop-backed ext4 data volume"
mkdir -p "$LAB/disks" /srv/data
dd if=/dev/zero of="$LAB/disks/data.img" bs=1M count=256 status=none
LOOP_DATA=$(losetup -f --show "$LAB/disks/data.img")
mkfs.ext4 -q -F -L LABDATA "$LOOP_DATA"
mount "$LOOP_DATA" /srv/data
mkdir -p /srv/data/uploads /srv/data/logs /srv/data/backups
chown -R deploy:devops /srv/data; chmod -R 2775 /srv/data
df -h /srv/data
# Persistent equivalent on a real VM (/etc/fstab):
#   UUID=<blkid output>  /srv/data  ext4  defaults,nofail  0  2

echo "### 6. sshd, one instance per server"
mkdir -p "$LAB/srv/web01" "$LAB/srv/app01" /run/sshd; chmod 0755 /run/sshd
for h in web01 app01; do
  [ -f "$LAB/srv/$h/ssh_host_ed25519_key" ] || \
    ssh-keygen -q -t ed25519 -N '' -f "$LAB/srv/$h/ssh_host_ed25519_key" -C "root@$h"
done
write_sshd() {
cat > "$LAB/srv/$1/sshd_config" <<EOF
Port 22
ListenAddress $2
HostKey $LAB/srv/$1/ssh_host_ed25519_key
PidFile /run/sshd-$1.pid
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication yes
UsePAM no
X11Forwarding no
LogLevel VERBOSE
AllowGroups devops sudo
Subsystem sftp /usr/lib/openssh/sftp-server
EOF
}
write_sshd web01 $WEB_IP
write_sshd app01 $APP_IP
chmod 600 "$LAB"/srv/*/ssh_host_ed25519_key
ip netns exec web01 /usr/sbin/sshd -f "$LAB/srv/web01/sshd_config" -E "$LAB/srv/web01/sshd.log"
ip netns exec app01 /usr/sbin/sshd -f "$LAB/srv/app01/sshd_config" -E "$LAB/srv/app01/sshd.log"

echo "### 7. SSH trust: sysadmin key from web01 to app01"
su - sysadmin -c 'test -f ~/.ssh/id_ed25519 || ssh-keygen -q -t ed25519 -N "" -f ~/.ssh/id_ed25519 -C sysadmin@web01'
su - sysadmin -c 'cat ~/.ssh/id_ed25519.pub > ~/.ssh/authorized_keys'
chmod 700 /home/sysadmin/.ssh; chmod 600 /home/sysadmin/.ssh/authorized_keys
ip netns exec web01 su - sysadmin -c "ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes $APP_IP 'echo SSH trust established'"

echo "### 8. nginx, one instance per server"
cat > /srv/webcontent/index.html <<'EOF'
<!doctype html><html><head><title>web01</title></head>
<body><h1>web01 - 10.10.10.11</h1><p>Nginx front-end node.</p></body></html>
EOF
cat > /srv/appcontent/index.html <<'EOF'
<!doctype html><html><head><title>app01</title></head>
<body><h1>app01 - 10.10.10.12:8080</h1><p>Application back-end node.</p></body></html>
EOF
gen_nginx() {   # $1=host $2=ip $3=port $4=docroot
mkdir -p "$LAB/srv/$1/logs"
cat > "$LAB/srv/$1/nginx.conf" <<EOF
user  www-data;
worker_processes  1;
pid /run/nginx-$1.pid;
error_log $LAB/srv/$1/logs/error.log warn;
events { worker_connections 512; }
http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    access_log $LAB/srv/$1/logs/access.log;
    sendfile on;
    server {
        listen       $2:$3;
        server_name  $1;
        root         $4;
        index        index.html;
        location /health { return 200 "OK $1\n"; add_header Content-Type text/plain; }
        location / { try_files \$uri \$uri/ =404; }
    }
}
EOF
}
gen_nginx web01 $WEB_IP 80   /srv/webcontent
gen_nginx app01 $APP_IP 8080 /srv/appcontent
ip netns exec web01 nginx -t -c "$LAB/srv/web01/nginx.conf"
ip netns exec app01 nginx -t -c "$LAB/srv/app01/nginx.conf"
ip netns exec web01 nginx -c "$LAB/srv/web01/nginx.conf" >/dev/null 2>&1
ip netns exec app01 nginx -c "$LAB/srv/app01/nginx.conf" >/dev/null 2>&1

echo "### 9. firewall: default-deny inbound on app01"
ip netns exec app01 iptables -F
ip netns exec app01 iptables -P INPUT ACCEPT
ip netns exec app01 iptables -A INPUT -i lo -j ACCEPT
ip netns exec app01 iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
ip netns exec app01 iptables -A INPUT -p icmp --icmp-type echo-request -m limit --limit 5/sec -j ACCEPT
ip netns exec app01 iptables -A INPUT -p tcp -s $WEB_IP --dport 22 -m conntrack --ctstate NEW -j ACCEPT
ip netns exec app01 iptables -A INPUT -p tcp --dport 8080 -j ACCEPT
ip netns exec app01 iptables -A INPUT -j LOG --log-prefix "FW-DROP-IN: " --log-level 4
ip netns exec app01 iptables -P INPUT DROP
ip netns exec app01 iptables -L INPUT -n -v

echo "### 10. verify"
ip netns exec web01 curl -s http://$WEB_IP/health
ip netns exec web01 curl -s http://$APP_IP:8080/health
ip netns exec web01 ss -tlnp
echo "LAB READY"
