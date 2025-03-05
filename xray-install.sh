#!/bin/bash

# Colors for better readability
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to display status messages
log() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

# Function to display success messages
success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# Function to display error messages
error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to display warning messages
warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Function to check command execution status
check_status() {
    if [ $? -eq 0 ]; then
        success "$1"
    else
        error "$2"
        exit 1
    fi
}

# Check if script is run as root
if [ "$(id -u)" -ne 0 ]; then
    error "This script must be run as root or with sudo privileges."
    exit 1
fi

# Check required dependencies
log "Checking required dependencies..."
for cmd in curl vim xxd; do
    if ! command -v $cmd &> /dev/null; then
        warning "$cmd is not installed. Installing..."
        apt-get update && apt-get install -y $cmd
        check_status "$cmd installed successfully." "Failed to install $cmd."
    fi
done

# Step 1: Install XRay using the latest version
log "Installing XRay with the latest version..."
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
check_status "XRay installed successfully." "Failed to install XRay."

# Step 2: Generate UUID and private key
log "Generating UUID and private key..."
cd /usr/local/bin/
xray uuid | tee /tmp/uuid > /dev/null
check_status "UUID generated successfully." "Failed to generate UUID."

xray x25519 | tee /tmp/key > /dev/null
check_status "Private key generated successfully." "Failed to generate private key."

# Read the generated UUID and private key
UUID=$(cat /tmp/uuid)
PRIVATE_KEY=$(grep -oP 'Private key: \K[a-zA-Z0-9]+' /tmp/key)
PUBLIC_KEY=$(grep -oP 'Public key: \K[a-zA-Z0-9]+' /tmp/key)

# Check if UUID and private key are empty
if [ -z "$UUID" ] || [ -z "$PRIVATE_KEY" ]; then
    error "Failed to extract UUID or private key."
    exit 1
fi

# Step 3: Display the generated UUID and keys
log "Generated keys:"
echo "UUID: $UUID"
echo "Private Key: $PRIVATE_KEY"
echo "Public Key: $PUBLIC_KEY"

# Step 4: Create XRay configuration
log "Creating XRay configuration..."
CONFIG_DIR="/usr/local/etc/xray"
CONFIG_FILE="$CONFIG_DIR/config.json"

# Backup existing config if it exists
if [ -f "$CONFIG_FILE" ]; then
    mv "$CONFIG_FILE" "${CONFIG_FILE}.backup-$(date +%Y%m%d%H%M%S)"
    warning "Existing configuration backed up."
fi

# Create the new configuration file
cat > "$CONFIG_FILE" << EOF
{
    "log": {
        "loglevel": "debug",
        "access": "/var/log/xray/access.log",
        "error": "/var/log/xray/error.log"
    },
    "inbounds": [
        {
            "port": 443,
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": "$UUID",
                        "flow": "xtls-rprx-vision"
                    }
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "dest": "www.apple.com:443",
                    "serverNames": [
                        "images.apple.com",
                        "www.apple.com",
                        "www.apple.com.cn"
                    ],
                    "privateKey": "$PRIVATE_KEY",
                    "shortIds": [
                        ""
                    ]
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": [
                    "http",
                    "tls",
                    "quic"
                ],
                "routeOnly": true
            }
        }
    ],
    "outbounds": [
        {
            "protocol": "freedom",
            "tag": "direct"
        },
        {
            "protocol": "blackhole",
            "tag": "blocked"
        }
    ]
}
EOF

check_status "XRay configuration created successfully." "Failed to create XRay configuration."

# Step 5: Restart XRay service
log "Restarting XRay service..."
systemctl restart xray
check_status "XRay service restarted successfully." "Failed to restart XRay service."

# Check if XRay service is running
log "Checking XRay service status..."
if systemctl is-active --quiet xray; then
    success "XRay service is running."
else
    error "XRay service is not running. Check the logs with 'journalctl -xeu xray'."
    exit 1
fi

# Step 6: Enable BBR acceleration
log "Enabling BBR acceleration..."

# Check current TCP congestion control algorithm
current_algorithm=$(sysctl -n net.ipv4.tcp_congestion_control)
if [ "$current_algorithm" = "bbr" ]; then
    success "BBR is already enabled."
else
    log "Enabling BBR..."
    
    # Check if the settings already exist in sysctl.conf to avoid duplication
    if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    fi
    
    if ! grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    fi
    
    # Apply the changes
    sysctl -p
    
    # Verify BBR is now enabled
    new_algorithm=$(sysctl -n net.ipv4.tcp_congestion_control)
    if [ "$new_algorithm" = "bbr" ]; then
        success "BBR has been enabled successfully."
    else
        warning "BBR could not be enabled. Current algorithm: $new_algorithm"
    fi
fi

# Check for qrencode
log "Checking for qrencode..."
if ! command -v qrencode &> /dev/null; then
    warning "qrencode is not installed. Installing..."
    apt-get update && apt-get install -y qrencode
    check_status "qrencode installed successfully." "Failed to install qrencode."
fi

# Generate VLESS URL
SERVER_IP=$(curl -s ifconfig.me)
REMARK=$(hostname)-$(date +%m%d)

# URL encode the remark
ENCODED_REMARK=$(echo -n "$REMARK" | xxd -plain | tr -d '\n' | sed 's/\(..\)/%\1/g')

# Create VLESS link
VLESS_LINK="vless://$UUID@$SERVER_IP:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.apple.com&fp=chrome&pbk=$PUBLIC_KEY&spx=%2F&type=tcp&headerType=none#$ENCODED_REMARK"

# Generate QR code and display it in terminal
log "Generating QR code and displaying in terminal..."
echo -n "$VLESS_LINK" | qrencode -t ANSI
check_status "QR code displayed successfully" "Failed to generate QR code."

# Save QR code to file as well for reference
QRCODE_FILE="/root/xray_vless_qrcode.png"
echo -n "$VLESS_LINK" | qrencode -s 10 -o "$QRCODE_FILE"
log "QR code also saved to $QRCODE_FILE"

# Final summary and connection information
log "XRay installation and configuration completed successfully."
echo ""
echo "==== XRay Connection Information ===="
echo "Protocol: VLESS"
echo "Server Address: $SERVER_IP"
echo "Port: 443"
echo "UUID: $UUID"
echo "Flow: xtls-rprx-vision"
echo "Network: tcp"
echo "Security: reality"
echo "Server Names: images.apple.com, www.apple.com, www.apple.com.cn"
echo "Destination: www.apple.com:443"
echo "Public Key: $PUBLIC_KEY"
echo "===================================="
echo ""
echo "VLESS Link:"
echo "$VLESS_LINK"
echo ""
echo "QR Code has been saved to: $QRCODE_FILE"
echo ""
echo "To check service status: sudo service xray status"
echo "To restart service: sudo service xray restart"
echo "Log files are located at: /var/log/xray/"
echo ""
success "Setup completed successfully!"
