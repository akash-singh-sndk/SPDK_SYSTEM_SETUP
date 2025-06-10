#!/bin/bash

# Script to set up SPDK on Ubuntu with Python virtual environment and verify the setup
# Run as root: sudo ./spdk_setup_aks.sh
# Assumes NVMe device at 0000:01:00.0 (SanDisk WD PC SN810, vendor:device 15b7:5011)

# Exit on any error
set -e

# Variables
SPDK_PARENT_DIR="/home/test-user/"
SPDK_DIR="/home/test-user/spdk"
NVME_BDF="0000:01:00.0"
VENDOR_DEVICE="15b7 5011"
HELLO_WORLD="${SPDK_DIR}/build/examples/hello_world"
IDENTIFY="${SPDK_DIR}/build/bin/spdk_nvme_identify"
UBUNTU_USER="test-user"
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

# Check IOMMU
print_status "Checking IOMMU"
if ! dmesg | grep -q -e DMAR -e IOMMU; then
    echo "Enabling IOMMU in GRUB..."
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="intel_iommu=on /' /etc/default/grub
    update-grub
    echo "Warning: IOMMU enabled. Please reboot and re-run the script."
    exit 1
fi
IOMMU_GROUP=$(find /sys/kernel/iommu_groups/ -type l | grep "$NVME_BDF")
if [ -z "$IOMMU_GROUP" ]; then
    echo "Error: NVMe device $NVME_BDF not in an IOMMU group."
    exit 1
fi
echo "IOMMU enabled, device in group: $IOMMU_GROUP"

# Load vfio-pci module
print_status "Loading vfio-pci module"
if ! lsmod | grep -q vfio_pci; then
    modprobe vfio-pci
fi
if ! lsmod | grep -q vfio_pci; then
    echo "Error: Failed to load vfio-pci module."
    exit 1
fi
echo "vfio-pci module loaded."

# Bind NVMe device to vfio-pci
print_status "Binding NVMe device $NVME_BDF to vfio-pci"
DRIVER=$(readlink -f /sys/bus/pci/devices/$NVME_BDF/driver 2>/dev/null | grep -o '[^/]*$' || true)
if [ "$DRIVER" = "nvme" ]; then
    echo "Unbinding $NVME_BDF from nvme driver..."
    echo "$NVME_BDF" > /sys/bus/pci/devices/$NVME_BDF/driver/unbind 2>/dev/null || true
fi
if [ "$DRIVER" != "vfio-pci" ]; then
    echo "Binding $NVME_BDF to vfio-pci..."
    echo "$VENDOR_DEVICE" > /sys/bus/pci/drivers/vfio-pci/new_id 2>/dev/null || true
    echo "$NVME_BDF" > /sys/bus/pci/drivers/vfio-pci/bind 2>/dev/null || {
        echo "Warning: Binding to vfio-pci failed. Checking if already bound..."
        if [ "$(readlink -f /sys/bus/pci/devices/$NVME_BDF/driver 2>/dev/null | grep -o '[^/]*$')" != "vfio-pci" ]; then
            echo "Error: Failed to bind $NVME_BDF to vfio-pci."
            exit 1
        fi
    }
fi
if [ "$(readlink -f /sys/bus/pci/devices/$NVME_BDF/driver 2>/dev/null | grep -o '[^/]*$')" != "vfio-pci" ]; then
    echo "Error: NVMe device $NVME_BDF not bound to vfio-pci."
    exit 1
fi
echo "NVMe device $NVME_BDF bound to vfio-pci."

# Build SPDK and DPDK
print_status "Building SPDK and DPDK"
cd "$SPDK_DIR"
./configure --without-nvme-cuse
make -j$(nproc)
cd examples/nvme/hello_world
make
echo "SPDK and DPDK build completed."

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

# Test SPDK setup
print_status "Testing SPDK setup with spdk_nvme_identify"
$IDENTIFY
echo "spdk_nvme_identify test completed."

print_status "Testing SPDK setup with hello_world"
$HELLO_WORLD
echo "hello_world test completed."

print_status "SPDK setup and tests completed successfully"
echo "SPDK setup and tests completed successfully."
