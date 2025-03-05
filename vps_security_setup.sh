#!/bin/bash

# VPS Security Setup Script
# This script automates security settings for Ubuntu VPS
# - System updates
# - New user creation with sudo privileges
# - SSH security configuration (disable root login, change port)
# - Firewall setup

# Exit on any error
set -e

# Text colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Function to print colored messages
print_message() {
    echo -e "${GREEN}[+] $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}[!] $1${NC}"
}

print_error() {
    echo -e "${RED}[-] $1${NC}"
}

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    print_error "This script must be run as root or with sudo privileges"
    exit 1
fi

# Welcome message
print_message "Starting VPS security setup"
echo "=============================================="

# Collect information
read -p "Enter new username to create: " NEW_USERNAME
while [[ -z "$NEW_USERNAME" ]]; do
    print_error "Username cannot be empty"
    read -p "Enter new username to create: " NEW_USERNAME
done

# Generate a random password or ask for one
read -p "Enter password for new user (leave blank for auto-generated): " USER_PASSWORD
if [[ -z "$USER_PASSWORD" ]]; then
    USER_PASSWORD=$(openssl rand -base64 12)
    print_warning "Auto-generated password: $USER_PASSWORD"
    print_warning "PLEASE SAVE THIS PASSWORD NOW!"
    echo ""
fi

read -p "Enter new SSH port (default: 8422): " SSH_PORT
SSH_PORT=${SSH_PORT:-8422}

# Step 1: System Updates
print_message "Updating system packages..."
apt-get update -y
apt-get upgrade -y

# Step 2: Create new user with sudo privileges
print_message "Creating new user: $NEW_USERNAME"
if id "$NEW_USERNAME" &>/dev/null; then
    print_warning "User $NEW_USERNAME already exists"
else
    # Create user with home directory
    useradd -m -s /bin/bash "$NEW_USERNAME"
    
    # Set password
    echo "$NEW_USERNAME:$USER_PASSWORD" | chpasswd
    
    # Add to sudo group
    usermod -aG sudo "$NEW_USERNAME"
    
    print_message "User $NEW_USERNAME created with sudo privileges"
fi

# Step 3: Configure SSH
print_message "Configuring SSH..."
SSH_CONFIG="/etc/ssh/sshd_config"
SSH_CONFIG_BACKUP="/etc/ssh/sshd_config.backup.$(date +%Y%m%d%H%M%S)"

# Backup original config
cp "$SSH_CONFIG" "$SSH_CONFIG_BACKUP"
print_message "SSH config backed up to $SSH_CONFIG_BACKUP"

# Update SSH config
sed -i "s/^#*Port .*/Port $SSH_PORT/" "$SSH_CONFIG"
sed -i "s/^#*PermitRootLogin .*/PermitRootLogin no/" "$SSH_CONFIG"
sed -i "s/^#*PasswordAuthentication .*/PasswordAuthentication yes/" "$SSH_CONFIG"
sed -i "s/^#*PubkeyAuthentication .*/PubkeyAuthentication yes/" "$SSH_CONFIG"

print_message "SSH configuration updated:"
print_message "  - Root login disabled"
print_message "  - SSH port changed to $SSH_PORT"

# Restart SSH service
systemctl restart ssh
print_message "SSH service restarted"

# Step 4: Configure firewall
print_message "Configuring firewall..."

# Reset UFW to default
ufw --force reset

# Set default policies
ufw default deny incoming
ufw default allow outgoing

# Allow SSH on custom port
ufw allow "$SSH_PORT/tcp" comment "SSH"

# Allow common web ports
ufw allow 80/tcp comment "HTTP"
ufw allow 443/tcp comment "HTTPS"

# Enable firewall
print_warning "Enabling UFW firewall..."
ufw --force enable

# Show status
ufw status verbose

# Final message
echo ""
echo "=============================================="
print_message "VPS SECURITY SETUP COMPLETE"
echo ""
print_message "IMPORTANT INFORMATION:"
echo "=============================================="
echo "New user: $NEW_USERNAME"
echo "Password: $USER_PASSWORD"
echo "SSH Port: $SSH_PORT"
echo ""
print_warning "NEXT STEPS:"
echo "1. Log in with the new user: ssh $NEW_USERNAME@your_server_ip -p $SSH_PORT"
echo "2. Set up SSH key authentication for better security"
echo "3. Consider disabling password authentication after setting up SSH keys"
echo "=============================================="

exit 0
