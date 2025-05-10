#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Banner
echo -e "${PURPLE}"
echo -e "   ___  ___  ___ _  _    ___ _ __   __ _ _ __ _ __ "
echo -e "  / __|/ _ \/ __| || |  / __| '_ \ / _\` | '__| '__|"
echo -e " | (__| (_) \__ \ || | | (__| |_) | (_| | |  | |   "
echo -e "  \___|\___/|___/\_, |  \___| .__/ \__,_|_|  |_|   "
echo -e "                 |__/       |_|                     "
echo -e "${CYAN}             Cloudflare Argo Tunnel Manager${NC}"
echo -e "${YELLOW}                  Made by Obscuraworks, Inc.${NC}\n"

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
  echo -e "${RED}This script must be run as root${NC}"
  exit 1
fi

# Function to update system
update_system() {
  echo -e "${YELLOW}Updating system packages...${NC}"
  apt update && apt upgrade -y
  if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to update system packages${NC}"
    exit 1
  fi
  echo -e "${GREEN}System updated successfully${NC}"
}

# Function to check dependencies
check_dependencies() {
  local dependencies=("wget" "dpkg" "systemctl")
  for dep in "${dependencies[@]}"; do
    if ! command -v $dep &> /dev/null; then
      echo -e "${RED}Error: $dep is not installed${NC}"
      exit 1
    fi
  done
}

# Function to install Cloudflared
install_cloudflared() {
  echo -e "${YELLOW}Installing Cloudflared...${NC}"
  
  # Check if cloudflared is already installed
  if command -v cloudflared &> /dev/null; then
    current_version=$(cloudflared --version | awk '{print $3}')
    echo -e "${YELLOW}Cloudflared is already installed (Version: $current_version)${NC}"
    read -p "Do you want to reinstall? (y/n): " reinstall
    if [[ ! $reinstall =~ ^[Yy]$ ]]; then
      return
    fi
    remove_bin
  fi
  
  # Update system before installation
  update_system
  
  # Download and install
  echo -e "${BLUE}Downloading the latest Cloudflared...${NC}"
  wget -q --show-progress https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -O /tmp/cloudflared-linux-amd64.deb
  if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to download Cloudflared${NC}"
    exit 1
  fi
  
  echo -e "${BLUE}Installing Cloudflared...${NC}"
  dpkg -i /tmp/cloudflared-linux-amd64.deb
  if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to install Cloudflared${NC}"
    exit 1
  fi
  
  # Verify installation
  installed_version=$(cloudflared --version | awk '{print $3}')
  echo -e "${GREEN}Cloudflared installed successfully (Version: $installed_version)${NC}"
}

# Function to create a new tunnel
create_tunnel() {
  echo -e "\n${YELLOW}Creating a new tunnel...${NC}"
  
  # Check if Cloudflared is installed
  if ! command -v cloudflared &> /dev/null; then
    echo -e "${RED}Cloudflared is not installed. Please install it first.${NC}"
    return
  fi
  
  # Login if not already
  if [ ! -d ~/.cloudflared ]; then
    echo -e "${BLUE}You need to authenticate with Cloudflare. Please follow the instructions...${NC}"
    cloudflared login
    if [ $? -ne 0 ]; then
      echo -e "${RED}Cloudflare login failed${NC}"
      return
    fi
  fi
  
  # Get tunnel name
  while true; do
    read -p "Enter tunnel name (letters, numbers, hyphens only): " tunnel_name
    if [[ $tunnel_name =~ ^[a-zA-Z0-9-]+$ ]]; then
      break
    else
      echo -e "${RED}Invalid tunnel name. Only letters, numbers and hyphens are allowed.${NC}"
    fi
  done
  
  # Create tunnel
  echo -e "${BLUE}Creating tunnel '$tunnel_name'...${NC}"
  cloudflared tunnel create $tunnel_name
  if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to create tunnel${NC}"
    return
  fi
  
  # Create config directory
  mkdir -p /etc/cloudflared
  
  # Build config file
  config_file="/etc/cloudflared/config.yml"
  cred_file=$(find /root/.cloudflared -type f -name "*.json" | head -n 1)
  echo "# Tunnel configuration" > $config_file
  echo "tunnel: $tunnel_name" >> $config_file
  echo "credentials-file: $cred_file" >> $config_file
  echo "logfile: /var/log/cloudflared.log" >> $config_file
  echo "loglevel: info" >> $config_file
  echo "" >> $config_file
  echo "ingress:" >> $config_file
  
  # Add hostnames and services
  echo -e "\n${CYAN}Add your hostnames and services (press enter to finish)${NC}"
  i=1
  while true; do
    echo -e "\n${YELLOW}Rule #$i${NC}"
    read -p "Hostname (e.g., example.com) or leave empty to finish: " hostname
    if [ -z "$hostname" ]; then
      break
    fi
    
    read -p "Service URL or port (e.g., http://localhost:8080 or just 8080): " service
    
    # If only port number is provided
    if [[ $service =~ ^[0-9]+$ ]]; then
      service="http://localhost:$service"
    fi
    
    # Validate service URL
    if [[ ! $service =~ ^https?:// ]]; then
      echo -e "${RED}Invalid service URL. Must start with http:// or https://${NC}"
      continue
    fi
    
    echo "  - hostname: $hostname" >> $config_file
    echo "    service: $service" >> $config_file
    
    # Add DNS route
    echo -e "${BLUE}Creating DNS route for $hostname...${NC}"
    cloudflared tunnel route dns $tunnel_name $hostname
    if [ $? -ne 0 ]; then
      echo -e "${YELLOW}Warning: Failed to create DNS route for $hostname${NC}"
    fi
    
    ((i++))
  done
  
  # Add catch-all rule
  echo "  - service: http_status:404" >> $config_file
  
  echo -e "\n${GREEN}Tunnel configuration created at $config_file${NC}"
  echo -e "${YELLOW}Here's your configuration:${NC}"
  cat $config_file
  
  # Run the tunnel temporarily to test
  echo -e "\n${BLUE}Testing the tunnel...${NC}"
  timeout 10 cloudflared tunnel run $tunnel_name &
  sleep 5
  
  # Install as service
  echo -e "\n${BLUE}Setting up as a system service...${NC}"
  cloudflared service install
  systemctl enable cloudflared
  systemctl restart cloudflared
  
  echo -e "\n${GREEN}Tunnel '$tunnel_name' is now running and configured to start on boot${NC}"
  echo -e "${CYAN}Service status:${NC}"
  systemctl status cloudflared --no-pager
  
  # Show tunnel info
  echo -e "\n${CYAN}Tunnel information:${NC}"
  cloudflared tunnel info $tunnel_name
}

# Function to remove tunnel binaries
remove_bin() {
  echo -e "\n${YELLOW}Removing Cloudflared binary...${NC}"
  
  if ! command -v cloudflared &> /dev/null; then
    echo -e "${YELLOW}Cloudflared is not installed${NC}"
    return
  fi
  
  # Stop service first
  systemctl stop cloudflared 2>/dev/null
  systemctl disable cloudflared 2>/dev/null
  
  # Remove binary
  echo -e "${BLUE}Uninstalling Cloudflared...${NC}"
  dpkg -r cloudflared
  rm -f /tmp/cloudflared-linux-amd64.deb
  
  echo -e "${GREEN}Cloudflared binary removed${NC}"
}

# Function to remove cache
remove_cache() {
  echo -e "\n${YELLOW}Removing Cloudflared cache...${NC}"
  
  if [ ! -d ~/.cloudflared ]; then
    echo -e "${YELLOW}No Cloudflared cache found${NC}"
    return
  fi
  
  echo -e "${BLUE}Removing cache files...${NC}"
  rm -rf ~/.cloudflared
  
  echo -e "${GREEN}Cloudflared cache removed${NC}"
}

# Function to remove all tunnels
remove_all_tunnels() {
  echo -e "\n${YELLOW}Removing all tunnels...${NC}"
  
  if ! command -v cloudflared &> /dev/null; then
    echo -e "${YELLOW}Cloudflared is not installed${NC}"
    return
  fi
  
  # Stop service first
  systemctl stop cloudflared 2>/dev/null
  systemctl disable cloudflared 2>/dev/null
  
  # Get list of tunnels
  echo -e "${BLUE}Fetching list of tunnels...${NC}"
  tunnels=$(cloudflared tunnel list | awk 'NR>1 {print $1}')
  
  if [ -z "$tunnels" ]; then
    echo -e "${YELLOW}No tunnels found${NC}"
    return
  fi
  
  # Delete each tunnel
  for tunnel in $tunnels; do
    echo -e "${RED}Deleting tunnel: $tunnel${NC}"
    cloudflared tunnel delete -f $tunnel
  done
  
  # Remove config directory
  rm -rf /etc/cloudflared
  
  echo -e "${GREEN}All tunnels removed${NC}"
}

# Function to completely uninstall
complete_uninstall() {
  echo -e "\n${RED}Completely uninstalling Cloudflared...${NC}"
  
  # Stop and disable service
  echo -e "${BLUE}Stopping services...${NC}"
  systemctl stop cloudflared 2>/dev/null
  systemctl disable cloudflared 2>/dev/null
  
  # Remove service files
  echo -e "${BLUE}Removing service files...${NC}"
  rm -f /etc/systemd/system/cloudflared.service
  systemctl daemon-reload
  
  # Remove binary
  if command -v cloudflared &> /dev/null; then
    echo -e "${BLUE}Removing Cloudflared binary...${NC}"
    dpkg -r cloudflared
    rm -f /tmp/cloudflared-linux-amd64.deb
  fi
  
  # Remove config and cache
  echo -e "${BLUE}Removing configuration and cache...${NC}"
  rm -rf /etc/cloudflared
  rm -rf ~/.cloudflared
  
  # Clean up
  echo -e "${BLUE}Cleaning up...${NC}"
  apt autoremove -y
  apt clean
  
  echo -e "\n${GREEN}Cloudflared completely uninstalled${NC}"
}

# Function to show tunnel status
show_status() {
  echo -e "\n${CYAN}Current Cloudflared Status${NC}"
  
  if ! command -v cloudflared &> /dev/null; then
    echo -e "${YELLOW}Cloudflared is not installed${NC}"
    return
  fi
  
  # Show version
  echo -e "${YELLOW}Version:${NC}"
  cloudflared --version
  
  # Show service status
  echo -e "\n${YELLOW}Service Status:${NC}"
  systemctl status cloudflared --no-pager
  
  # List tunnels
  echo -e "\n${YELLOW}Existing Tunnels:${NC}"
  cloudflared tunnel list
  
  # Show running tunnels
  echo -e "\n${YELLOW}Running Tunnels:${NC}"
  for tunnel in $(cloudflared tunnel list | awk 'NR>1 {print $1}'); do
    echo -e "${BLUE}Tunnel: $tunnel${NC}"
    cloudflared tunnel info $tunnel | grep -E 'Name|Connections|Status'
    echo
  done
}

# Main menu
while true; do
  echo -e "\n${PURPLE}Main Menu${NC}"
  echo -e "${GREEN}1. Install/Update Cloudflared & Create Tunnel${NC}"
  echo -e "${CYAN}2. Show Tunnel Status${NC}"
  echo -e "${RED}3. Remove Cloudflared Binary${NC}"
  echo -e "${YELLOW}4. Remove Cloudflared Cache${NC}"
  echo -e "${RED}5. Remove All Tunnels${NC}"
  echo -e "${RED}6. Complete Uninstall (Remove Everything)${NC}"
  echo -e "${BLUE}7. Exit${NC}"
  
  read -p "$(echo -e ${CYAN}'Choose an option (1-7): '${NC})" choice
  
  case $choice in
    1)
      check_dependencies
      install_cloudflared
      create_tunnel
      ;;
    2)
      show_status
      ;;
    3)
      remove_bin
      ;;
    4)
      remove_cache
      ;;
    5)
      remove_all_tunnels
      ;;
    6)
      complete_uninstall
      ;;
    7)
      echo -e "${BLUE}Exiting...${NC}"
      exit 0
      ;;
    *)
      echo -e "${RED}Invalid option${NC}"
      ;;
  esac
done
