#!/bin/bash

# Author:    Akash Kumar Singh
# Email:     akash.singh@sandisk.com

# Script to set up SPDK on Ubuntu with Python virtual environment and verify the setup
# Run as root: sudo ./spdk_setup_aks.sh
# Assumes NVMe device at 0000:01:00.0 (SanDisk WD PC SN810, vendor:device 15b7:5011)
set -e

# Variables
SPDK_PARENT_DIR="/home/test_user/"
SPDK_DIR="/home/test_user/spdk"
NVME_BDF="0000:03:00.0"
VENDOR_DEVICE="15b7 5045"
HELLO_WORLD="${SPDK_DIR}/build/examples/hello_world"
IDENTIFY="${SPDK_DIR}/build/bin/spdk_nvme_identify"
UBUNTU_USER="test_user"
VENV_DIR="${SPDK_DIR}/venv"

# Function to print status
print_status() {
    echo "=== $1 ==="
}

# Check if running as root
print_status "Checking for root privileges"
if [ "$EUID" -ne 0 ]; then
    echo "Error: This script must be run as root (use sudo)."
    exit 1
fi

# # Remove existing $SPDK_DIR if it exists
# if [ -d "$SPDK_DIR" ]; then
#     echo "Removing existing SPDK directory $SPDK_DIR..."
#     rm -rf "$SPDK_DIR"
# fi

# # Create SPDK Parent directory
# mkdir -p "$SPDK_PARENT_DIR"
# print_status "Creating SPDK directory at $SPDK_PARENT_DIR"
# mkdir -p "$SPDK_PARENT_DIR"
# echo "SPDK directory created at $SPDK_PARENT_DIR."

# # Ensure SPDK_DIR is owned by the user
# chown -R "$UBUNTU_USER:$UBUNTU_USER" "$SPDK_PARENT_DIR"

# # Ensure SPDK_DIR is writable by the user
# chmod -R u+w "$SPDK_PARENT_DIR"

# # Ensure SPDK_DIR is accessible
# chmod -R a+rx "$SPDK_PARENT_DIR"

# Install dependencies
print_status "Installing dependencies"
apt-get update -y
apt-get install -y gcc make git libnuma-dev libaio-dev libssl-dev libibverbs-dev \
    librdmacm-dev meson ninja-build libfuse3-dev libcunit1-dev uuid-dev libncurses-dev \
    python3 python3-pip python3-venv
echo "Dependencies installation attempted."

# Verify dependencies
print_status "Verifying dependencies"
for pkg in gcc make git libnuma-dev libaio-dev libssl-dev libibverbs-dev \
    librdmacm-dev meson ninja-build libfuse3-dev libcunit1-dev uuid-dev libncurses-dev \
    python3 python3-pip python3-venv; do
    if ! dpkg -l | grep -q "$pkg"; then
        echo "Error: Package $pkg is not installed."
        exit 1
    fi
done
echo "All dependencies verified."

# Configure hugepages
print_status "Configuring hugepages"
HUGE_TOTAL=$(grep HugePages_Total /proc/meminfo | awk '{print $2}')
if [ "$HUGE_TOTAL" -lt 2048 ]; then
    echo "Setting 2048 hugepages..."
    echo 2048 > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages
    mkdir -p /mnt/huge
    mount -t hugetlbfs nodev /mnt/huge
fi
HUGE_TOTAL=$(grep HugePages_Total /proc/meminfo | awk '{print $2}')
if [ "$HUGE_TOTAL" -lt 2048 ]; then
    echo "Error: Failed to set 2048 hugepages."
    exit 1
fi
echo "Hugepages set: $HUGE_TOTAL"

# Configure memlock limit
print_status "Checking memlock limit"
MEMLOCK=$(ulimit -l)
if [ "$MEMLOCK" != "unlimited" ] && [ "$MEMLOCK" -lt 8210688 ]; then
    echo "Setting memlock limit to unlimited..."
    echo "root hard memlock unlimited" >> /etc/security/limits.conf
    echo "root soft memlock unlimited" >> /etc/security/limits.conf
    echo "Warning: Memlock limit updated. Please reboot and re-run the script."
    exit 1
fi
echo "Memlock limit: $MEMLOCK KB"

# # Clone SPDK if not present
cd "$SPDK_PARENT_DIR"
print_status "Current directory: $(pwd)"
print_status "Checking SPDK directory"
if [ -d "$SPDK_DIR/.git" ]; then
    echo "SPDK repository already cloned."
else
    echo "Cloning SPDK repository..."
    echo "Creating SPDK directory at $SPDK_DIR..."
    cd "$SPDK_PARENT_DIR"
    git clone https://github.com/spdk/spdk.git
    cd "$SPDK_DIR"
    git submodule update --init
fi
echo "SPDK repository verified."

# Set up Python virtual environment
print_status "Setting up Python virtual environment"
if [ ! -d "$VENV_DIR" ]; then
    echo "Creating virtual environment at $VENV_DIR..."
    python3 -m venv "$VENV_DIR"
    chown -R "$UBUNTU_USER:$UBUNTU_USER" "$VENV_DIR"
fi
source "${VENV_DIR}/bin/activate"
pip install --upgrade pip
pip install pyelftools
if ! python3 -c "import elftools" 2>/dev/null; then
    echo "Error: pyelftools is not installed in virtual environment."
    exit 1
fi
echo "Python virtual environment set up with pyelftools."

# Build SPDK and DPDK
print_status "Building SPDK and DPDK"
cd "$SPDK_DIR"
make clean
sudo ./configure --without-nvme-cuse
make -j$(nproc)
cd examples/nvme/hello_world
make
echo "SPDK and DPDK build completed."

# Bind NVMe device using SPDK setup.sh
print_status "Binding NVMe device using SPDK setup.sh"
cd "$SPDK_DIR"
sudo scripts/setup.sh
echo "NVMe device binding attempted."
sudo scripts/setup.sh status
echo "NVMe device status checked."

# Verify binaries
print_status "Verifying SPDK binaries"
if [ ! -x "$IDENTIFY" ]; then
    echo "Error: $IDENTIFY not found."
    exit 1
fi
if [ ! -x "$HELLO_WORLD" ]; then
    echo "Error: $HELLO_WORLD not found."
    exit 1
fi
echo "SPDK binaries verified."

# Check IOMMU
print_status "Checking IOMMU"
if ! dmesg | grep -q -e DMAR -e IOMMU; then
    echo "Enabling IOMMU in GRUB..."
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="intel_iommu=on /' /etc/default/grub
    update-grub
    echo "Warning: IOMMU enabled. Please reboot and re-run the script."
    exit 1
fi
echo "IOMMU enabled."

# Test SPDK setup
print_status "Testing SPDK setup with spdk_nvme_identify"
$IDENTIFY
echo "spdk_nvme_identify test completed."

print_status "Testing SPDK setup with hello_world"
$HELLO_WORLD
echo "hello_world test completed."

print_status "SPDK setup and tests completed successfully"
echo "SPDK setup and tests completed successfully."
