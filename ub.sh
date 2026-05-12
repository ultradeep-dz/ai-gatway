#!/bin/bash
# ============================================================
# Termux Full Server Setup Script
# Goal: Android phone → 24/7 self-hosted OpenClash server
#       accessible via SSH from anywhere using srvio.root.sx
# ============================================================
# HOW TO USE:
#   1. Open Termux on your Android phone
#   2. Run: curl -sL https://raw.githubusercontent.com/ultradeep-dz/ai-gatway/refs/heads/main/ub.sh | bash
#      OR copy this file to Termux and run: bash termux_setup.sh
# ============================================================

set -e

FREEDNS_UPDATE_URL="https://freedns.afraid.org/dynamic/update.php?VmEzdXZSVFJxZDJzc1BvRVhuS0lQUzRpOjI1OTg5ODc2"
# ⚠️  IMPORTANT: Replace YOUR_TOKEN_HERE with your actual FreeDNS token.
# Find it at: https://freedns.afraid.org/dynamic/ → click "Direct URL" next to srvio.root.sx
# It looks like: https://freedns.afraid.org/dynamic/update.php?abc123xyz...

DOMAIN="srvio.root.sx"

echo "======================================"
echo "  Termux Server Setup Starting..."
echo "======================================"

# ── STEP 1: Update Termux & install dependencies ──────────────
echo "[1/7] Updating Termux packages..."
pkg update -y && pkg upgrade -y
pkg install -y proot-distro curl wget openssh termux-services

# ── STEP 2: Install Ubuntu 24 via proot-distro ────────────────
echo "[2/7] Installing Ubuntu 24 (proot-distro)..."
proot-distro install ubuntu || echo "Ubuntu already installed, skipping."

# ── STEP 3: Setup SSH inside Ubuntu ──────────────────────────
echo "[3/7] Configuring OpenSSH inside Ubuntu..."
proot-distro login ubuntu -- bash -c '
  apt update -y && apt upgrade -y
  apt install -y openssh-server curl wget cron

  # Configure SSHD
  mkdir -p /run/sshd
  sed -i "s/#Port 22/Port 2222/" /etc/ssh/sshd_config
  sed -i "s/#PermitRootLogin prohibit-password/PermitRootLogin yes/" /etc/ssh/sshd_config
  sed -i "s/#PasswordAuthentication yes/PasswordAuthentication yes/" /etc/ssh/sshd_config

  # Set root password (change "yourpassword" to something strong!)
  echo "root:yourpassword" | chpasswd

  echo "SSH configured on port 2222"
'

# ── STEP 4: Install OpenClash inside Ubuntu ───────────────────
echo "[4/7] Installing OpenClash (Clash) inside Ubuntu..."
proot-distro login ubuntu -- bash -c '
  apt install -y clash || true

  # If clash not in apt, download binary directly
  if ! command -v clash &>/dev/null; then
    ARCH=$(uname -m)
    if [ "$ARCH" = "aarch64" ]; then
      wget -q "https://github.com/Dreamacro/clash/releases/latest/download/clash-linux-arm64-v3.gz" -O /tmp/clash.gz
    else
      wget -q "https://github.com/Dreamacro/clash/releases/latest/download/clash-linux-armv7.gz" -O /tmp/clash.gz
    fi
    gunzip /tmp/clash.gz -c > /usr/local/bin/clash
    chmod +x /usr/local/bin/clash
  fi

  mkdir -p /etc/clash /root/.config/clash

  # Basic Clash config (edit /etc/clash/config.yaml to add your proxies)
  cat > /etc/clash/config.yaml << "CLASHCONF"
mixed-port: 7890
allow-lan: true
mode: rule
log-level: info
external-controller: 0.0.0.0:9090
proxies: []
proxy-groups: []
rules:
  - MATCH,DIRECT
CLASHCONF

  # Clash systemd-style service via cron @reboot
  echo "@reboot root /usr/local/bin/clash -d /etc/clash/ &" >> /etc/crontab

  echo "OpenClash (Clash core) installed."
'

# ── STEP 5: FreeDNS Dynamic Update Client ────────────────────
echo "[5/7] Setting up FreeDNS dynamic DNS updater..."
proot-distro login ubuntu -- bash -c "
  # Create the update script
  cat > /usr/local/bin/freedns-update.sh << 'EOF'
#!/bin/bash
# FreeDNS Dynamic DNS updater for srvio.root.sx
LOGFILE=/var/log/freedns-update.log
UPDATE_URL=\"${FREEDNS_UPDATE_URL}\"

CURRENT_IP=\$(curl -s https://api.ipify.org)
LAST_IP_FILE=/tmp/freedns_last_ip.txt
LAST_IP=\$(cat \$LAST_IP_FILE 2>/dev/null || echo '')

if [ \"\$CURRENT_IP\" != \"\$LAST_IP\" ]; then
  RESULT=\$(curl -s \"\$UPDATE_URL\")
  echo \"\$(date): IP changed \$LAST_IP → \$CURRENT_IP | FreeDNS response: \$RESULT\" >> \$LOGFILE
  echo \"\$CURRENT_IP\" > \$LAST_IP_FILE
else
  echo \"\$(date): IP unchanged (\$CURRENT_IP), no update needed.\" >> \$LOGFILE
fi
EOF
  chmod +x /usr/local/bin/freedns-update.sh

  # Add to crontab: run every 5 minutes + on reboot
  (crontab -l 2>/dev/null; echo '*/5 * * * * /usr/local/bin/freedns-update.sh') | crontab -
  (crontab -l 2>/dev/null; echo '@reboot sleep 10 && /usr/local/bin/freedns-update.sh') | crontab -

  # Start cron
  service cron start || cron

  echo 'FreeDNS updater configured. Runs every 5 minutes.'
"

# ── STEP 6: Auto-start everything on Termux boot ─────────────
echo "[6/7] Configuring auto-start on Termux boot..."

# Create Termux:Boot script (requires Termux:Boot app installed)
mkdir -p ~/.termux/boot

cat > ~/.termux/boot/start-ubuntu-server.sh << 'EOF'
#!/data/data/com.termux/files/usr/bin/bash
# Auto-start on Android boot (requires Termux:Boot app)
# Termux:Boot app: https://f-droid.org/packages/com.termux.boot/

# Prevent CPU sleep
termux-wake-lock

# Start Ubuntu with SSH + FreeDNS + Clash
proot-distro login ubuntu -- bash -c '
  # Start SSH
  mkdir -p /run/sshd
  /usr/sbin/sshd

  # Start Cron (handles FreeDNS updates + Clash autostart)
  service cron start || cron &

  # Start Clash directly
  nohup /usr/local/bin/clash -d /etc/clash/ > /var/log/clash.log 2>&1 &

  # Run FreeDNS update immediately
  /usr/local/bin/freedns-update.sh

  echo "Server started at $(date)"
' &
EOF

chmod +x ~/.termux/boot/start-ubuntu-server.sh

# ── STEP 7: First launch ─────────────────────────────────────
echo "[7/7] Starting server for the first time..."
proot-distro login ubuntu -- bash -c '
  mkdir -p /run/sshd
  /usr/sbin/sshd
  service cron start || cron &
  nohup /usr/local/bin/clash -d /etc/clash/ > /var/log/clash.log 2>&1 &
  /usr/local/bin/freedns-update.sh
  echo "✅ All services started."
' &

echo ""
echo "======================================"
echo "  ✅ SETUP COMPLETE!"
echo "======================================"
echo ""
echo "  SSH Access (from anywhere):"
echo "  ssh root@${DOMAIN} -p 2222"
echo "  Password: yourpassword  ← CHANGE THIS!"
echo ""
echo "  OpenClash Dashboard:"
echo "  http://${DOMAIN}:9090"
echo ""
echo "  FreeDNS updates every 5 min."
echo "  Domain: ${DOMAIN}"
echo ""
echo "  ⚠️  TODO AFTER RUNNING:"
echo "  1. Replace YOUR_TOKEN_HERE in this script with your"
echo "     actual FreeDNS Direct URL token."
echo "     Get it from: https://freedns.afraid.org/dynamic/"
echo "  2. Change SSH password from 'yourpassword' to something strong."
echo "  3. Install Termux:Boot from F-Droid for auto-start on reboot."
echo "     https://f-droid.org/packages/com.termux.boot/"
echo "  4. Edit /etc/clash/config.yaml inside Ubuntu to add your proxies."
echo "  5. Keep phone plugged in & disable battery optimization for Termux."
echo "======================================"
