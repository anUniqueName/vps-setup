#!/bin/bash

# VPS Security Setup Script with Comprehensive Error Handling
# This script automates security settings for Ubuntu VPS
# - System updates
# - New user creation with sudo privileges
# - SSH security configuration (disable root login, change port)
# - Firewall setup

# Text colors and formatting
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
BOLD='\033[1m'
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

print_info() {
    echo -e "${BLUE}[*] $1${NC}"
}

print_step() {
    echo -e "\n${BOLD}== $1 ==${NC}"
}

# Log file setup
LOG_FILE="/var/log/vps_security_setup.log"
exec > >(tee -a "$LOG_FILE") 2>&1

# Welcome message
echo -e "\n${BOLD}==============================================${NC}"
echo -e "${BOLD}     VPS SECURITY SETUP SCRIPT     ${NC}"
echo -e "${BOLD}==============================================${NC}"
print_info "Started at: $(date)"
print_info "All operations will be logged to $LOG_FILE"
echo -e "${BOLD}==============================================${NC}\n"

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    print_error "This script must be run as root or with sudo privileges"
    print_info "Try running: sudo $0"
    exit 1
fi

# Ensure required tools are available
check_required_tools() {
    print_step "Checking Required Tools"
    
    local missing_tools=()
    
    for tool in wget openssl sed grep findmnt; do
        if ! command -v $tool &>/dev/null; then
            missing_tools+=("$tool")
        fi
    done
    
    if [ ${#missing_tools[@]} -gt 0 ]; then
        print_warning "Some required tools are missing. Installing them now..."
        
        # Disable interactive prompts for apt
        export DEBIAN_FRONTEND=noninteractive
        
        apt-get update -y || {
            print_error "Failed to update package list. Network issues?"
            print_info "Please check your internet connection and try again."
            exit 1
        }
        
        for tool in "${missing_tools[@]}"; do
            print_info "Installing $tool..."
            apt-get install -y $tool || {
                print_error "Failed to install $tool"
            }
        done
    else
        print_message "All required tools are available"
    fi
}

# Trap for script interruption
cleanup() {
    print_warning "Script interrupted! Cleaning up..."
    print_info "Check $LOG_FILE for details on what was completed"
    exit 1
}
trap cleanup SIGINT SIGTERM

# Function to handle errors
handle_error() {
    print_error "$1"
    print_info "$2"
    
    if [ "$3" == "fatal" ]; then
        print_error "Fatal error. Exiting script."
        exit 1
    else
        read -p "Do you want to continue with the script? (y/n): " choice
        if [[ ! $choice =~ ^[Yy]$ ]]; then
            print_warning "Script execution stopped by user"
            exit 1
        fi
        print_warning "Continuing script execution..."
    fi
}

# Check system
check_system() {
    print_step "Checking System"
    
    # Check if system is Ubuntu
    if ! grep -qi "ubuntu" /etc/os-release; then
        print_warning "This script is designed for Ubuntu systems"
        print_info "Your system: $(grep -i "PRETTY_NAME" /etc/os-release | cut -d= -f2 | tr -d '"')"
        read -p "Do you want to continue anyway? (y/n): " choice
        if [[ ! $choice =~ ^[Yy]$ ]]; then
            print_warning "Script execution stopped by user"
            exit 1
        fi
    else
        print_message "Ubuntu system detected: $(grep -i "VERSION=" /etc/os-release | cut -d= -f2 | tr -d '"')"
    fi
    
    # Check disk space
    root_space=$(df -h / | awk 'NR==2 {print $4}')
    print_info "Available disk space: $root_space"
    
    if df -h / | awk 'NR==2 {exit ($4+0 < 1)}'; then
        print_message "Sufficient disk space available"
    else
        print_warning "Less than 1GB of free disk space available, updates might fail"
        read -p "Continue anyway? (y/n): " choice
        if [[ ! $choice =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
    
    # Check for pending reboots
    if [ -f /var/run/reboot-required ]; then
        print_warning "System reboot is pending. It's recommended to reboot before running this script."
        read -p "Continue anyway? (y/n): " choice
        if [[ ! $choice =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
}

# Collect user information
collect_user_info() {
    print_step "Collecting User Information"
    
    # Get username
    while true; do
        read -p "Enter new username to create: " NEW_USERNAME
        if [[ -z "$NEW_USERNAME" ]]; then
            print_error "Username cannot be empty"
            continue
        fi
        
        if [[ "$NEW_USERNAME" =~ [^a-z0-9_] ]]; then
            print_error "Username must only contain lowercase letters, numbers, and underscores"
            continue
        fi
        
        if id "$NEW_USERNAME" &>/dev/null; then
            print_warning "User $NEW_USERNAME already exists"
            read -p "Use existing user? (y/n): " choice
            if [[ $choice =~ ^[Yy]$ ]]; then
                USER_EXISTS=true
                break
            else
                continue
            fi
        else
            USER_EXISTS=false
            break
        fi
    done
    
    # Get password if creating new user
    if [ "$USER_EXISTS" = false ]; then
        while true; do
            read -p "Enter password for new user (leave blank for auto-generated): " USER_PASSWORD
            if [[ -z "$USER_PASSWORD" ]]; then
                USER_PASSWORD=$(openssl rand -base64 12)
                print_warning "Auto-generated password: $USER_PASSWORD"
                print_warning "PLEASE SAVE THIS PASSWORD NOW!"
                echo ""
                break
            else
                # Check password strength
                if [ ${#USER_PASSWORD} -lt 8 ]; then
                    print_error "Password too short (minimum 8 characters)"
                    continue
                fi
                break
            fi
        done
    fi
    
    # Get SSH port
    while true; do
        read -p "Enter new SSH port (default: 8422): " SSH_PORT
        SSH_PORT=${SSH_PORT:-8422}
        
        if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || [ "$SSH_PORT" -lt 1024 ] || [ "$SSH_PORT" -gt 65535 ]; then
            print_error "Invalid port. Please enter a number between 1024 and 65535"
            continue
        fi
        
        # Check if port is already in use
        if command -v ss &>/dev/null && ss -tuln | grep -q ":$SSH_PORT "; then
            print_warning "Port $SSH_PORT is already in use"
            read -p "Choose a different port? (y/n): " choice
            if [[ $choice =~ ^[Yy]$ ]]; then
                continue
            fi
        fi
        
        break
    done
    
    print_message "User information collected successfully"
}

# Fix system packages
fix_system_packages() {
    print_step "Fixing System Packages"
    
    # Disable interactive prompts for apt
    export DEBIAN_FRONTEND=noninteractive
    
    print_info "Checking for broken packages..."
    if ! apt-get --fix-broken install -y; then
        handle_error "Failed to fix broken packages" "This might affect system updates" "non-fatal"
    else
        print_message "No broken packages found or all fixed successfully"
    fi
    
    print_info "Configuring pending packages..."
    
    # Handle btrfs hook issue proactively
    if [ -f /usr/share/initramfs-tools/hooks/btrfs ]; then
        # Check if btrfs is in use
        if grep -q btrfs /etc/fstab || findmnt -t btrfs &>/dev/null; then
            print_info "BTRFS filesystem detected, ensuring btrfs-progs is installed..."
            apt-get install -y btrfs-progs
        else
            print_info "BTRFS not in use, temporarily disabling btrfs hook..."
            mv /usr/share/initramfs-tools/hooks/btrfs /usr/share/initramfs-tools/hooks/btrfs.disabled
            print_message "Disabled btrfs hook temporarily"
        fi
    fi
    
    # Configure pending packages
    if ! dpkg --configure -a; then
        print_warning "Some issues occurred while configuring packages"
        print_info "This is non-fatal, continuing with script..."
    else
        print_message "All pending packages configured successfully"
    fi
    
    # Restore btrfs hook if we disabled it
    if [ -f /usr/share/initramfs-tools/hooks/btrfs.disabled ]; then
        mv /usr/share/initramfs-tools/hooks/btrfs.disabled /usr/share/initramfs-tools/hooks/btrfs
        print_message "Restored btrfs hook"
    fi
}

# Update system packages
update_system() {
    print_step "Updating System Packages"
    
    # Disable interactive prompts for apt
    export DEBIAN_FRONTEND=noninteractive
    
    print_info "Updating package lists..."
    if ! apt-get update -y; then
        handle_error "Failed to update package lists" "Check your internet connection and sources.list" "non-fatal"
    else
        print_message "Package lists updated successfully"
    fi
    
    # Fix potential initramfs-tools issues
    if dpkg -l | grep -q "initramfs-tools"; then
        print_info "Ensuring initramfs-tools is properly configured..."
        
        # Handle btrfs hook issue
        if [ -f /usr/share/initramfs-tools/hooks/btrfs ]; then
            # Check if btrfs is in use
            if grep -q btrfs /etc/fstab || findmnt -t btrfs &>/dev/null; then
                print_info "BTRFS filesystem detected, ensuring btrfs-progs is installed..."
                apt-get install -y btrfs-progs
            else
                print_info "BTRFS not in use, temporarily disabling btrfs hook..."
                mv /usr/share/initramfs-tools/hooks/btrfs /usr/share/initramfs-tools/hooks/btrfs.disabled
                print_message "Disabled btrfs hook temporarily"
            fi
        fi
        
        # Reinstall initramfs-tools
        print_info "Reinstalling initramfs-tools package..."
        apt-get install --reinstall -y initramfs-tools || {
            print_warning "Failed to reinstall initramfs-tools. This is non-fatal."
        }
    fi
    
    print_info "Upgrading packages..."
    if ! apt-get upgrade -y; then
        print_warning "Some package upgrades failed. This is non-fatal."
        print_info "Attempting to fix broken packages..."
        apt-get --fix-broken install -y
    else
        print_message "All packages upgraded successfully"
    fi
    
    # Try to install packages that were kept back
    print_info "Checking for held back packages..."
    held_back=$(apt-get upgrade -s | grep -c "kept back")
    if [ "$held_back" -gt 0 ]; then
        print_info "Found held back packages, attempting to install them..."
        apt-get dist-upgrade -y || {
            print_warning "Some held back packages could not be installed. This is non-fatal."
        }
    fi
    
    # Restore btrfs hook if we disabled it
    if [ -f /usr/share/initramfs-tools/hooks/btrfs.disabled ]; then
        mv /usr/share/initramfs-tools/hooks/btrfs.disabled /usr/share/initramfs-tools/hooks/btrfs
        print_message "Restored btrfs hook"
    fi
    
    # Run autoremove to clean up
    print_info "Removing unnecessary packages..."
    apt-get autoremove -y
}

# Create a new user
create_user() {
    print_step "Creating User"
    
    if [ "$USER_EXISTS" = true ]; then
        print_info "Using existing user: $NEW_USERNAME"
    else
        print_info "Creating new user: $NEW_USERNAME"
        
        # Create user with home directory
        if ! useradd -m -s /bin/bash "$NEW_USERNAME"; then
            handle_error "Failed to create user $NEW_USERNAME" "User creation error" "fatal"
        fi
        
        # Set password
        print_info "Setting password for $NEW_USERNAME..."
        if ! echo "$NEW_USERNAME:$USER_PASSWORD" | chpasswd; then
            handle_error "Failed to set password for $NEW_USERNAME" "Password setup error" "fatal"
        fi
        
        print_message "User $NEW_USERNAME created successfully"
    fi
    
    # Add to sudo group
    print_info "Adding user to sudo group..."
    if ! usermod -aG sudo "$NEW_USERNAME"; then
        handle_error "Failed to add $NEW_USERNAME to sudo group" "User will not have administrative privileges" "non-fatal"
    else
        print_message "User $NEW_USERNAME added to sudo group successfully"
    fi
    
    # Verify sudo access
    print_info "Verifying sudo access..."
    if ! groups "$NEW_USERNAME" | grep -q "\bsudo\b"; then
        print_warning "Could not verify sudo access for $NEW_USERNAME"
        print_info "You may need to configure sudo access manually"
    else
        print_message "Sudo group membership verified for $NEW_USERNAME"
    fi
}

# Configure SSH
configure_ssh() {
    print_step "Configuring SSH"
    
    SSH_CONFIG="/etc/ssh/sshd_config"
    SSH_CONFIG_BACKUP="/etc/ssh/sshd_config.backup.$(date +%Y%m%d%H%M%S)"
    
    # Check if SSH config exists
    if [ ! -f "$SSH_CONFIG" ]; then
        print_info "SSH config not found. Installing OpenSSH server..."
        apt-get install -y openssh-server || {
            handle_error "Failed to install OpenSSH server" "SSH setup failed" "fatal"
        }
    fi
    
    # Backup original config
    print_info "Backing up SSH configuration..."
    if ! cp "$SSH_CONFIG" "$SSH_CONFIG_BACKUP"; then
        handle_error "Failed to backup SSH configuration" "Cannot proceed without backup" "fatal"
    else
        print_message "SSH config backed up to $SSH_CONFIG_BACKUP"
    fi
    
    # Update SSH config
    print_info "Updating SSH configuration..."
    
    # Check if port is already configured
    if grep -q "^Port $SSH_PORT" "$SSH_CONFIG"; then
        print_info "SSH port $SSH_PORT is already configured"
    else
        # Update Port configuration
        if grep -q "^Port " "$SSH_CONFIG"; then
            # Port directive exists, update it
            sed -i "s/^Port .*/Port $SSH_PORT/" "$SSH_CONFIG" || {
                handle_error "Failed to update SSH port" "SSH configuration error" "non-fatal"
            }
        elif grep -q "^#Port " "$SSH_CONFIG"; then
            # Port directive is commented, uncomment and update it
            sed -i "s/^#Port .*/Port $SSH_PORT/" "$SSH_CONFIG" || {
                handle_error "Failed to update SSH port" "SSH configuration error" "non-fatal"
            }
        else
            # Port directive doesn't exist, add it
            echo "Port $SSH_PORT" >> "$SSH_CONFIG" || {
                handle_error "Failed to add SSH port" "SSH configuration error" "non-fatal"
            }
        fi
    fi
    
    # Update PermitRootLogin - similar approach as Port
    if grep -q "^PermitRootLogin " "$SSH_CONFIG"; then
        sed -i "s/^PermitRootLogin .*/PermitRootLogin no/" "$SSH_CONFIG" || {
            handle_error "Failed to disable root login" "SSH configuration error" "non-fatal"
        }
    elif grep -q "^#PermitRootLogin " "$SSH_CONFIG"; then
        sed -i "s/^#PermitRootLogin .*/PermitRootLogin no/" "$SSH_CONFIG" || {
            handle_error "Failed to disable root login" "SSH configuration error" "non-fatal"
        }
    else
        echo "PermitRootLogin no" >> "$SSH_CONFIG" || {
            handle_error "Failed to add root login config" "SSH configuration error" "non-fatal"
        }
    fi
    
    # Update PasswordAuthentication
    if grep -q "^PasswordAuthentication " "$SSH_CONFIG"; then
        sed -i "s/^PasswordAuthentication .*/PasswordAuthentication yes/" "$SSH_CONFIG" || {
            handle_error "Failed to enable password authentication" "SSH configuration error" "non-fatal"
        }
    elif grep -q "^#PasswordAuthentication " "$SSH_CONFIG"; then
        sed -i "s/^#PasswordAuthentication .*/PasswordAuthentication yes/" "$SSH_CONFIG" || {
            handle_error "Failed to enable password authentication" "SSH configuration error" "non-fatal"
        }
    else
        echo "PasswordAuthentication yes" >> "$SSH_CONFIG" || {
            handle_error "Failed to add password authentication config" "SSH configuration error" "non-fatal"
        }
    fi
    
    # Update PubkeyAuthentication
    if grep -q "^PubkeyAuthentication " "$SSH_CONFIG"; then
        sed -i "s/^PubkeyAuthentication .*/PubkeyAuthentication yes/" "$SSH_CONFIG" || {
            handle_error "Failed to enable pubkey authentication" "SSH configuration error" "non-fatal"
        }
    elif grep -q "^#PubkeyAuthentication " "$SSH_CONFIG"; then
        sed -i "s/^#PubkeyAuthentication .*/PubkeyAuthentication yes/" "$SSH_CONFIG" || {
            handle_error "Failed to enable pubkey authentication" "SSH configuration error" "non-fatal"
        }
    else
        echo "PubkeyAuthentication yes" >> "$SSH_CONFIG" || {
            handle_error "Failed to add pubkey authentication config" "SSH configuration error" "non-fatal"
        }
    fi
    
    print_message "SSH configuration updated:"
    print_message "  - Root login disabled"
    print_message "  - SSH port changed to $SSH_PORT"
    print_message "  - Password authentication enabled"
    print_message "  - Public key authentication enabled"
    
    # Validate SSH config
    print_info "Validating SSH configuration..."
    if command -v sshd &>/dev/null; then
        if ! sshd -t; then
            handle_error "SSH configuration is invalid" "Reverting to backup" "non-fatal"
            cp "$SSH_CONFIG_BACKUP" "$SSH_CONFIG"
            print_warning "Reverted to original SSH configuration"
        else
            print_message "SSH configuration is valid"
        fi
    else
        print_warning "Could not validate SSH configuration (sshd command not available)"
    fi
    
    # Restart SSH service
    print_info "Restarting SSH service..."
    if systemctl is-active ssh &>/dev/null; then
        if ! systemctl restart ssh; then
            handle_error "Failed to restart SSH service" "Reverting to backup" "non-fatal"
            cp "$SSH_CONFIG_BACKUP" "$SSH_CONFIG"
            systemctl restart ssh || {
                print_error "Failed to restart SSH service with original configuration"
                print_warning "Please restore SSH manually: cp $SSH_CONFIG_BACKUP $SSH_CONFIG"
            }
        else
            print_message "SSH service restarted successfully"
        fi
    elif systemctl is-active sshd &>/dev/null; then
        if ! systemctl restart sshd; then
            handle_error "Failed to restart SSH service" "Reverting to backup" "non-fatal"
            cp "$SSH_CONFIG_BACKUP" "$SSH_CONFIG"
            systemctl restart sshd || {
                print_error "Failed to restart SSH service with original configuration"
                print_warning "Please restore SSH manually: cp $SSH_CONFIG_BACKUP $SSH_CONFIG"
            }
        else
            print_message "SSH service restarted successfully"
        fi
    else
        print_warning "SSH service not found, please start it manually"
        print_info "Try: systemctl start ssh"
    fi
}

# Configure firewall
configure_firewall() {
    print_step "Configuring Firewall"
    
    # Check if UFW is installed
    if ! command -v ufw &>/dev/null; then
        print_info "UFW not found, installing..."
        if ! apt-get install -y ufw; then
            handle_error "Failed to install UFW" "Firewall setup failed" "non-fatal"
            return 1
        else
            print_message "UFW installed successfully"
        fi
    fi
    
    # Check current UFW status
    print_info "Checking current firewall status..."
    ufw status
    
    # Reset UFW to default
    print_info "Resetting firewall to defaults..."
    if ! ufw --force reset; then
        handle_error "Failed to reset UFW" "Firewall configuration error" "non-fatal"
        return 1
    else
        print_message "Firewall reset to defaults"
    fi
    
    # Set default policies
    print_info "Setting default policies..."
    ufw default deny incoming
    ufw default allow outgoing
    
    # Allow SSH on custom port
    print_info "Adding rule for SSH on port $SSH_PORT..."
    if ! ufw allow "$SSH_PORT/tcp" comment "SSH"; then
        handle_error "Failed to add SSH rule" "Firewall rule error" "non-fatal"
    else
        print_message "Added rule for SSH on port $SSH_PORT"
    fi
    
    # Allow common web ports
    print_info "Adding rules for HTTP and HTTPS..."
    if ! ufw allow 80/tcp comment "HTTP"; then
        handle_error "Failed to add HTTP rule" "Firewall rule error" "non-fatal"
    else
        print_message "Added rule for HTTP on port 80"
    fi
    
    if ! ufw allow 443/tcp comment "HTTPS"; then
        handle_error "Failed to add HTTPS rule" "Firewall rule error" "non-fatal"
    else
        print_message "Added rule for HTTPS on port 443"
    fi
    
    # Enable firewall
    print_warning "Enabling UFW firewall..."
    if ! ufw --force enable; then
        handle_error "Failed to enable UFW" "Firewall not enabled" "non-fatal"
        return 1
    else
        print_message "Firewall enabled successfully"
    fi
    
    # Show status
    print_info "Current firewall status:"
    ufw status verbose
}

# Summary and final steps
show_summary() {
    print_step "Setup Summary"
    
    echo -e "${BOLD}==============================================${NC}"
    print_message "VPS SECURITY SETUP COMPLETE"
    echo -e "${BOLD}==============================================${NC}"
    print_message "IMPORTANT INFORMATION:"
    echo "New user: $NEW_USERNAME"
    if [ "$USER_EXISTS" = false ]; then
        echo "Password: $USER_PASSWORD"
    fi
    echo "SSH Port: $SSH_PORT"
    
    # Check firewall status
    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        echo -e "\n${BOLD}FIREWALL RULES${NC}"
        ufw status | grep -v "Status"
    fi
    
    echo -e "\n${BOLD}NEXT STEPS${NC}"
    echo "1. Log in with the new user: ssh $NEW_USERNAME@your_server_ip -p $SSH_PORT"
    echo "2. Test sudo access with: sudo whoami"
    
    if [ -f "/var/run/reboot-required" ]; then
        print_warning "A system reboot is recommended to complete all updates"
        echo "   Run: sudo reboot"
    fi
    
    echo -e "${BOLD}==============================================${NC}"
    print_info "Log file saved to: $LOG_FILE"
    echo -e "${BOLD}==============================================${NC}"
}

# Main function to run all steps
main() {
    check_required_tools
    check_system
    collect_user_info
    fix_system_packages
    update_system
    create_user
    configure_ssh
    configure_firewall
    show_summary
    
    print_info "Script completed at: $(date)"
    
    return 0
}

# Run the main function
main
