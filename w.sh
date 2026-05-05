#!/bin/bash

# ==========================================================
# Proxmox VE Wi-Fi Auto-Configurator
# SSID: dlink-C0FF
# PASS: saida1104
# WARNING: For testing only. Not recommended for production.
# ==========================================================

set -e

SSID="dlink-C0FF"
PASSWORD="saida1104"
WIFI_IFACE=""
BRIDGE_NAME="vmbr0"

echo ">>> Starting Proxmox Wi-Fi Configuration..."

# 1. Identify the Wi-Fi interface
echo ">>> Detecting Wi-Fi interface..."
WIFI_IFACE=$(ip link show | grep -i "wlan" | head -n 1 | awk -F': ' '{print $2}' | tr -d ' ')

if [ -z "$WIFI_IFACE" ]; then
    # Try finding any wireless interface
    WIFI_IFACE=$(iw dev | awk '$1=="Interface"{print $2}' | head -n 1)
fi

if [ -z "$WIFI_IFACE" ]; then
    echo "ERROR: No Wi-Fi interface detected. Please ensure your USB Ethernet/Wi-Fi adapter is plugged in and recognized."
    exit 1
fi

echo ">>> Found Wi-Fi interface: $WIFI_IFACE"

# 2. Ensure required packages are installed
echo ">>> Installing required packages (wpasupplicant, wireless-tools)..."
apt-get update -y
apt-get install -y wpasupplicant wireless-tools resolvconf

# 3. Generate wpa_supplicant config
echo ">>> Configuring WPA Supplicant for SSID: $SSID..."
cat > /etc/wpa_supplicant/wpa_supplicant.conf <<EOF
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=US

network={
    ssid="$SSID"
    psk="$PASSWORD"
    key_mgmt=WPA-PSK
}
EOF

# 4. Stop NetworkManager if running (Proxmox uses ifupdown by default)
systemctl stop NetworkManager 2>/dev/null || true
systemctl disable NetworkManager 2>/dev/null || true

# 5. Configure /etc/network/interfaces
echo ">>> Backing up original /etc/network/interfaces..."
cp /etc/network/interfaces /etc/network/interfaces.bak

echo ">>> Writing new network configuration..."
cat > /etc/network/interfaces <<EOF
auto lo
iface lo inet loopback

# Primary Ethernet interface (if present, keep it managed by DHCP)
# auto enp0s25  # Uncomment if you know your eth name
# iface enp0s25 inet dhcp

# Wi-Fi Interface Configuration
allow-hotplug $WIFI_IFACE
iface $WIFI_IFACE inet dhcp
    wpa-conf /etc/wpa_supplicant/wpa_supplicant.conf

# Optional: Bridge for VMs (NAT mode required for Wi-Fi)
# Note: Bridging Wi-Fi directly is problematic. 
# We will set up NAT later if needed.
EOF

# 6. Bring up the Wi-Fi interface
echo ">>> Bringing up interface $WIFI_IFACE..."
ifdown $WIFI_IFACE 2>/dev/null || true
ifup $WIFI_IFACE

# Wait for connection
echo ">>> Waiting for IP address..."
sleep 5

# Check if we got an IP
IP_ADDR=$(ip addr show $WIFI_IFACE | grep "inet " | awk '{print $2}')
if [ -z "$IP_ADDR" ]; then
    echo "WARNING: Failed to obtain IP address. Trying to restart wpa_supplicant..."
    wpa_cli -i $WIFI_IFACE reconfigure
    sleep 10
    IP_ADDR=$(ip addr show $WIFI_IFACE | grep "inet " | awk '{print $2}')
fi

if [ -n "$IP_ADDR" ]; then
    echo "SUCCESS! Wi-Fi connected. IP Address: $IP_ADDR"
else
    echo "ERROR: Could not connect to Wi-Fi. Check password and SSID."
    exit 1
fi

# 7. Enable IP Forwarding for VM NAT (Optional but recommended)
echo ">>> Enabling IP forwarding for VM NAT..."
sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
sysctl -p

echo ">>> Setup Complete!"
echo ">>> You can now access Proxmox Web UI at: https://$IP_ADDR:8006"
echo ">>> Note: If VMs need internet, configure them to use NAT behind vmbr0 or create a separate NAT bridge."
