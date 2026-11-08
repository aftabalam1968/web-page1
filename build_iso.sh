#!/usr/bin/env bash
# ==============================================================================
# Debian Custom Live ISO Builder for Remote Windows VM Connection (RDP Kiosk)
# ==============================================================================
set -e

if [ "$EUID" -ne 0 ]; then
  echo "Error: This script must be run as root (sudo bash build_iso.sh)"
  exit 1
fi

echo "[*] Installing build dependencies..."
apt-get update
apt-get install -y live-build debootstrap isolinux syslinux-common

BUILD_DIR="debian-rdp-live"
echo "[*] Setting up build workspace in ./${BUILD_DIR}..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

echo "[*] Initializing live-build configuration..."
lb config \
  --distribution bookworm \
  --archive-areas "main contrib non-free non-free-firmware" \
  --architectures amd64 \
  --bootloaders "syslinux,grub-efi" \
  --package-lists minimal

echo "[*] Adding required packages..."
cat << 'EOF' > config/package-lists/rdp-kiosk.list.chroot
xorg
openbox
nodm
freerdp2-x11
yad
network-manager
iproute2
sudo
curl
ca-certificates
zenity
EOF

echo "[*] Creating connection and IP configuration script..."
mkdir -p config/includes.chroot/usr/local/bin

cat << 'EOF' > config/includes.chroot/usr/local/bin/start-rdp.sh
#!/bin/bash

# Loop to restart dialog if connection drops or user closes RDP session
while true; do
  FORM_DATA=$(yad --form --title="VM & Network Configuration" \
    --text="<b>Network & Remote Windows VM Setup</b>" --center --width=480 \
    --field="Local Network IP Type:CB" "DHCP!Static" \
    --field="Local Static IP (CIDR, e.g. 192.168.1.50/24):TEXT" "" \
    --field="Local Gateway (e.g. 192.168.1.1):TEXT" "" \
    --field="Local DNS (e.g. 8.8.8.8):TEXT" "8.8.8.8" \
    --field="Windows VM IP / Hostname:TEXT" "" \
    --field="Windows VM Username:TEXT" "" \
    --field="Windows VM Password:H" "" \
    --button="Connect:0" --button="Exit:1")

  RET=$?
  [ $RET -ne 0 ] && break

  # Parse fields
  NET_TYPE=$(echo "$FORM_DATA" | awk -F'|' '{print $1}')
  LOCAL_IP=$(echo "$FORM_DATA" | awk -F'|' '{print $2}')
  LOCAL_GW=$(echo "$FORM_DATA" | awk -F'|' '{print $3}')
  LOCAL_DNS=$(echo "$FORM_DATA" | awk -F'|' '{print $4}')
  VM_IP=$(echo "$FORM_DATA" | awk -F'|' '{print $5}')
  VM_USER=$(echo "$FORM_DATA" | awk -F'|' '{print $6}')
  VM_PASS=$(echo "$FORM_DATA" | awk -F'|' '{print $7}')

  # Find active network interface
  NET_IF=$(ip route | grep default | awk '{print $5}' | head -n1)
  [ -z "$NET_IF" ] && NET_IF=$(ip -o link show | awk -F': ' '{print $2}' | grep -v "lo" | head -n1)

  # Configure local network IP
  if [ "$NET_TYPE" = "Static" ] && [ -n "$LOCAL_IP" ] && [ -n "$NET_IF" ]; then
    sudo ip addr flush dev "$NET_IF"
    sudo ip addr add "$LOCAL_IP" dev "$NET_IF"
    [ -n "$LOCAL_GW" ] && sudo ip route add default via "$LOCAL_GW" dev "$NET_IF"
    [ -n "$LOCAL_DNS" ] && echo "nameserver $LOCAL_DNS" | sudo tee /etc/resolv.conf
  fi

  # Connect to Windows VM
  if [ -n "$VM_IP" ]; then
    xfreerdp /v:"$VM_IP" /u:"$VM_USER" /p:"$VM_PASS" /f /cert:ignore /clipboard /sound:sys:alsa /dynamic-resolution
  fi

  # Sleep briefly before loop re-renders dialog
  sleep 1
done
EOF

chmod +x config/includes.chroot/usr/local/bin/start-rdp.sh

echo "[*] Setting up auto-start and auto-login..."
mkdir -p config/includes.chroot/etc/xdg/openbox
cat << 'EOF' > config/includes.chroot/etc/xdg/openbox/autostart
/usr/local/bin/start-rdp.sh &
EOF

mkdir -p config/includes.chroot/etc/default
cat << 'EOF' > config/includes.chroot/etc/default/nodm
NODM_ENABLED=true
NODM_USER=user
NODM_FIRST_VT=7
NODM_XSESSION=/etc/X11/Xsession
EOF

# Sudoers configuration for user without password
mkdir -p config/includes.chroot/etc/sudoers.d
echo "user ALL=(ALL) NOPASSWD: ALL" > config/includes.chroot/etc/sudoers.d/99-live-user
chmod 0440 config/includes.chroot/etc/sudoers.d/99-live-user

echo "[*] Configuration complete!"
echo "[*] Starting ISO build with live-build (lb build)..."
lb build

echo "[✔] Build completed successfully! Generated file: debian-rdp-live/live-image-amd64.hybrid.iso"
