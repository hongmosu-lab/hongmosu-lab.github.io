#!/bin/bash
# sv-bootstrap: one-shot deployment for Vultr sv-node-01 (Debian 13)
# Installs sing-box (Hysteria2 + Shadowsocks-2022 fallback), runs Google
# behaviour tests from the box, and publishes a status JSON over HTTP
# on an unguessable path for out-of-band verification. No secrets are
# embedded: passwords are generated on the box and reported via status.
exec > /var/log/sv-deploy.log 2>&1
set -x
export DEBIAN_FRONTEND=noninteractive

RANDPATH="s-k7x9p2mq48"
STATUS_DIR="/var/www-status"
STATUS_FILE="$STATUS_DIR/$RANDPATH/status.json"
mkdir -p "$STATUS_DIR/$RANDPATH"
echo '{"stage":"boot"}' > "$STATUS_FILE"

apt-get update -y
apt-get install -y curl jq openssl python3

# Serve the status directory on port 80 for out-of-band checks.
# Self-terminates after 30 minutes.
(python3 -m http.server 80 --directory "$STATUS_DIR" >/dev/null 2>&1 &)
(sleep 1800; pkill -f "http.server 80") &

# BBR
grep -q "tcp_congestion_control=bbr" /etc/sysctl.conf || {
  echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
  echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
}
sysctl -p || true
modprobe tcp_bbr || true

# sing-box (official deb install script; GitHub release as fallback)
if ! command -v sing-box >/dev/null 2>&1; then
  bash <(curl -fsSL https://sing-box.app/deb-install.sh) || true
fi
if ! command -v sing-box >/dev/null 2>&1; then
  TAG=$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name)
  VER=${TAG#v}
  curl -fsSL -o /tmp/sb.deb "https://github.com/SagerNet/sing-box/releases/download/$TAG/sing-box_${VER}_linux_amd64.deb"
  dpkg -i /tmp/sb.deb || apt-get install -f -y
fi
sing-box version

# Credentials generated on-box
HY2_PASS=$(openssl rand -hex 16)
SS_PASS=$(openssl rand -base64 16)
HY2_SNI="www.amazon.com"

mkdir -p /etc/sing-box
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -days 3650 -nodes \
  -keyout /etc/sing-box/key.pem -out /etc/sing-box/cert.pem -subj "/CN=$HY2_SNI" 2>/dev/null

cat > /etc/sing-box/config.json <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": 443,
      "users": [ { "name": "ming", "password": "$HY2_PASS" } ],
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "/etc/sing-box/cert.pem",
        "key_path": "/etc/sing-box/key.pem"
      }
    },
    {
      "type": "shadowsocks",
      "tag": "ss-in",
      "listen": "::",
      "listen_port": 8443,
      "method": "2022-blake3-aes-128-gcm",
      "password": "$SS_PASS"
    }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ]
}
EOF

sing-box check -c /etc/sing-box/config.json
systemctl enable sing-box || true
systemctl restart sing-box
sleep 3
SB_ACTIVE=$(systemctl is-active sing-box || echo unknown)
SB_VER=$(sing-box version | head -1)

# Google behaviour tests from this exit
G_SEARCH=$(curl -s -o /dev/null -w "%{http_code}|%{redirect_url}" --max-time 15 "https://www.google.com/search?q=test")
curl -s --max-time 15 "https://www.youtube.com/premium" -o /tmp/yt.html
if grep -q "not available in your country" /tmp/yt.html; then YT_BLOCKED=true; else YT_BLOCKED=false; fi
SGCN=$(dig +short services.googleapis.cn A 2>/dev/null | tr '\n' ',' || echo "nodig")
PUBIP=$(curl -s --max-time 10 https://ipinfo.io/ip || echo unknown)

jq -n \
  --arg stage "done" \
  --arg ipv4 "$PUBIP" \
  --arg singbox_version "$SB_VER" \
  --arg singbox_active "$SB_ACTIVE" \
  --arg hy2_pass "$HY2_PASS" \
  --arg hy2_sni "$HY2_SNI" \
  --arg ss_pass "$SS_PASS" \
  --arg google_search "$G_SEARCH" \
  --argjson yt_premium_blocked "$YT_BLOCKED" \
  --arg services_gcn_a "$SGCN" \
  '{
     stage: $stage,
     ipv4: $ipv4,
     singbox_version: $singbox_version,
     singbox_active: $singbox_active,
     hy2: { port: 443, password: $hy2_pass, sni: $hy2_sni, insecure: true },
     ss2022: { port: 8443, method: "2022-blake3-aes-128-gcm", password: $ss_pass },
     google: { search: $google_search, yt_premium_blocked: $yt_premium_blocked, services_googleapis_cn_A: $services_gcn_a }
   }' > "$STATUS_FILE"

echo "SV-DEPLOY-DONE"
