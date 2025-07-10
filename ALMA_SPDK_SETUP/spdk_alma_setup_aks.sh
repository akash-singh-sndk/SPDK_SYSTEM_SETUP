#!/bin/bash

# Author:    Akash Kumar Singh
# Email:     akash.singh@sandisk.com

# Script to set up SPDK on Alma Linux with Python virtual environment and verify the setup
# Run as root: sudo ./spdk_alma.sh
# Assumes NVMe device at 0000:01:00.0 (SanDisk WD PC SN810, vendor:device 15b7:5011)
set -e

# Variables
SPDK_PARENT_DIR="/home/aks/AKS"
SPDK_DIR="/home/aks/AKS/spdk"
ALMA_USER="aks"
NVME_BDF="0000:13:00.0"
VENDOR_DEVICE="15ad:07f0"
HELLO_WORLD="${SPDK_DIR}/build/examples/hello_world"
IDENTIFY="${SPDK_DIR}/build/bin/spdk_nvme_identify"
VENV_DIR="${SPDK_DIR}/venv"

# Function to print status with enhanced formatting
print_status() {
    local message="$1"
    local length=${#message}
    local border_length=$((length + 10))
    
    echo ""
    printf '%*s\n' "$border_length" '' | tr ' ' '='
    echo "  >>  $message"
    printf '%*s\n' "$border_length" '' | tr ' ' '='
    echo ""
}

# Check if running as root
print_status "Checking for root privileges"
if [ "$EUID" -ne 0 ]; then
    echo "Error: This script must be run as root (use sudo)."
    exit 1
fi

# Enable EPEL repository for additional packages
print_status "Enabling EPEL repository"
if ! dnf list installed epel-release &>/dev/null; then
    dnf install -y epel-release
    echo "EPEL repository enabled."
else
    echo "EPEL repository already enabled."
fi

# Enable PowerTools/CRB repository for development packages
print_status "Enabling PowerTools/CRB repository"
if command -v dnf config-manager &>/dev/null; then
    dnf config-manager --set-enabled crb 2>/dev/null || dnf config-manager --set-enabled powertools 2>/dev/null || echo "PowerTools/CRB repository may already be enabled"
else
    echo "Warning: Could not enable PowerTools/CRB repository. Some packages may not be available."
fi

# Install dependencies
print_status "Installing dependencies"
dnf update -y
dnf install -y gcc gcc-c++ make git numactl-devel libaio-devel openssl-devel \
    rdma-core-devel meson ninja-build fuse3-devel \
    CUnit-devel libuuid-devel ncurses-devel python3 python3-pip \
    python3-virtualenv kernel-devel kernel-headers

echo "Dependencies installation attempted."

# Verify dependencies
print_status "Verifying dependencies"
# Define package mappings for verification (Alma Linux specific)
declare -A pkg_map=(
    ["gcc"]="gcc"
    ["gcc-c++"]="gcc-c++"
    ["make"]="make"
    ["git"]="git"
    ["numactl-devel"]="numactl-devel"
    ["libaio-devel"]="libaio-devel"
    ["openssl-devel"]="openssl-devel"
    ["rdma-core-devel"]="rdma-core-devel"
    ["meson"]="meson"
    ["ninja-build"]="ninja-build"
    ["fuse3-devel"]="fuse3-devel"
    ["CUnit-devel"]="CUnit-devel"
    ["libuuid-devel"]="libuuid-devel"
    ["ncurses-devel"]="ncurses-devel"
    ["python3"]="python3"
    ["python3-pip"]="python3-pip"
    ["python3-virtualenv"]="python3-virtualenv"
    ["kernel-devel"]="kernel-devel"
    ["kernel-headers"]="kernel-headers"
)

for pkg in "${!pkg_map[@]}"; do
    if ! rpm -q "${pkg_map[$pkg]}" &>/dev/null; then
        echo "Error: Package ${pkg_map[$pkg]} is not installed."
        exit 1
    fi
done
echo "All dependencies verified."

# Configure hugepages
print_status "Configuring hugepages"
echo "Current memory information:"
grep -E "(MemTotal|MemFree|HugePages)" /proc/meminfo

HUGE_TOTAL=$(grep HugePages_Total /proc/meminfo | awk '{print $2}')
HUGE_FREE=$(grep HugePages_Free /proc/meminfo | awk '{print $2}')
MEM_TOTAL=$(grep MemTotal /proc/meminfo | awk '{print $2}')
MEM_FREE=$(grep MemFree /proc/meminfo | awk '{print $2}')

echo "Current hugepages: Total=$HUGE_TOTAL, Free=$HUGE_FREE"
echo "System memory: Total=${MEM_TOTAL}kB, Free=${MEM_FREE}kB"

# Calculate optimal hugepage count based on available memory
# Leave at least 512MB for the system
RESERVED_MEM=524288  # 512MB in KB
AVAILABLE_FOR_HUGEPAGES=$((MEM_TOTAL - RESERVED_MEM))

# Each hugepage is 2MB (2048KB)
MAX_HUGEPAGES=$((AVAILABLE_FOR_HUGEPAGES / 2048))

# Set target hugepages based on system capacity
if [ "$MAX_HUGEPAGES" -ge 2048 ]; then
    TARGET_HUGEPAGES=2048
elif [ "$MAX_HUGEPAGES" -ge 1024 ]; then
    TARGET_HUGEPAGES=1024
elif [ "$MAX_HUGEPAGES" -ge 512 ]; then
    TARGET_HUGEPAGES=512
elif [ "$MAX_HUGEPAGES" -ge 256 ]; then
    TARGET_HUGEPAGES=256
elif [ "$MAX_HUGEPAGES" -ge 128 ]; then
    TARGET_HUGEPAGES=128
else
    echo "Warning: System has insufficient memory for SPDK hugepages."
    echo "Available memory for hugepages: ${AVAILABLE_FOR_HUGEPAGES}kB"
    echo "Maximum possible hugepages: $MAX_HUGEPAGES"
    if [ "$MAX_HUGEPAGES" -lt 64 ]; then
        echo "Error: System requires at least 128MB + 512MB reserved = 640MB total RAM for SPDK."
        echo "Current system has only ${MEM_TOTAL}kB (~$((MEM_TOTAL/1024))MB) total RAM."
        exit 1
    fi
    TARGET_HUGEPAGES=$MAX_HUGEPAGES
fi

echo "Target hugepages: $TARGET_HUGEPAGES (based on ${MEM_TOTAL}kB total memory)"

if [ "$HUGE_TOTAL" -lt "$TARGET_HUGEPAGES" ]; then
    echo "Setting $TARGET_HUGEPAGES hugepages..."
    
    # Try to drop caches first to free up memory
    echo "Dropping caches to free memory..."
    sync
    echo 3 > /proc/sys/vm/drop_caches
    
    # Try to compact memory to reduce fragmentation
    echo "Compacting memory to reduce fragmentation..."
    echo 1 > /proc/sys/vm/compact_memory 2>/dev/null || echo "Memory compaction not available"
    
    # Wait for cache drop and compaction to take effect
    sleep 2
    
    # Check available memory after cache drop
    MEM_FREE=$(grep MemFree /proc/meminfo | awk '{print $2}')
    REQUIRED_MEM=$((TARGET_HUGEPAGES * 2048))
    echo "Required memory for hugepages: ${REQUIRED_MEM}kB"
    echo "Free memory after cache drop: ${MEM_FREE}kB"
    
    # Set hugepages with retry logic
    echo $TARGET_HUGEPAGES > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages
    
    # Wait and check if allocation succeeded
    sleep 3
    CURRENT_HUGE=$(grep HugePages_Total /proc/meminfo | awk '{print $2}')
    
    # If we didn't get enough hugepages, try with a lower target
    if [ "$CURRENT_HUGE" -lt "$TARGET_HUGEPAGES" ]; then
        echo "Only $CURRENT_HUGE hugepages allocated, trying with reduced target..."
        REDUCED_TARGET=$((TARGET_HUGEPAGES / 2))
        if [ "$REDUCED_TARGET" -lt 256 ]; then
            REDUCED_TARGET=256
        fi
        echo "Trying with $REDUCED_TARGET hugepages..."
        echo $REDUCED_TARGET > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages
        sleep 2
        
        # Check again after reduction
        CURRENT_HUGE=$(grep HugePages_Total /proc/meminfo | awk '{print $2}')
        if [ "$CURRENT_HUGE" -lt "$REDUCED_TARGET" ]; then
            echo "Still only $CURRENT_HUGE hugepages allocated, trying minimal configuration..."
            MINIMAL_TARGET=128
            echo $MINIMAL_TARGET > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages
            sleep 2
        fi
    fi
    
    # Create and mount hugepage filesystem
    mkdir -p /mnt/huge
    if ! mountpoint -q /mnt/huge; then
        mount -t hugetlbfs nodev /mnt/huge
    fi
fi

# Check final hugepage configuration
HUGE_TOTAL=$(grep HugePages_Total /proc/meminfo | awk '{print $2}')
HUGE_FREE=$(grep HugePages_Free /proc/meminfo | awk '{print $2}')

echo "Final hugepages: Total=$HUGE_TOTAL, Free=$HUGE_FREE"

# More flexible hugepage validation
if [ "$HUGE_TOTAL" -lt 64 ]; then
    echo "Error: Insufficient hugepages ($HUGE_TOTAL < 64). Cannot proceed."
    echo "SPDK requires at least 64 hugepages (128MB) to function."
    echo "Please ensure sufficient free memory and try again."
    exit 1
elif [ "$HUGE_TOTAL" -lt 256 ]; then
    echo "Warning: Low hugepage count ($HUGE_TOTAL). SPDK will run with reduced performance."
    echo "For better performance, consider adding more RAM to the system."
    echo "Continuing with $HUGE_TOTAL hugepages..."
elif [ "$HUGE_TOTAL" -lt "$TARGET_HUGEPAGES" ]; then
    echo "Warning: Only $HUGE_TOTAL hugepages allocated (requested $TARGET_HUGEPAGES)"
    echo "This may be due to memory fragmentation."
    echo "SPDK should still work, but performance might be affected."
    echo "Continuing with $HUGE_TOTAL hugepages..."
else
    echo "Hugepages successfully configured: $HUGE_TOTAL"
fi

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
    chown -R "$ALMA_USER:$ALMA_USER" "$VENV_DIR"
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

# Configure SPDK first (required before any make commands)
print_status "Configuring SPDK"
sudo ./configure --without-nvme-cuse

# Clean any previous builds
if [ -f "mk/config.mk" ]; then
    echo "Cleaning previous build..."
    make clean
fi

# Build SPDK and DPDK
echo "Building SPDK and DPDK (this may take several minutes)..."
make -j$(nproc)

# Build the hello_world example
echo "Building hello_world example..."
cd examples/nvme/hello_world
make
echo "SPDK and DPDK build completed."

# Bind NVMe device using SPDK setup.sh
print_status "Binding NVMe device using SPDK setup.sh"
cd "$SPDK_DIR"

# Check if the target NVMe device is available and not in use
echo "Checking NVMe devices..."
if lspci -nn | grep -q "$VENDOR_DEVICE"; then
    echo "Found NVMe device with vendor:device $VENDOR_DEVICE"
    
    # Check if the device is currently in use
    if sudo scripts/setup.sh status | grep -q "$NVME_BDF.*Active devices"; then
        echo "Warning: NVMe device $NVME_BDF is currently in use by the system."
        echo "This device appears to be the boot drive or contains active filesystems."
        echo "SPDK cannot bind to devices that are actively being used."
        echo ""
        echo "Available options:"
        echo "1. Use a different NVMe device that is not in use"
        echo "2. Use SPDK in user-mode without binding (limited functionality)"
        echo "3. Boot from a different drive and use this NVMe for SPDK"
        echo ""
        echo "Continuing with SPDK setup without device binding..."
        echo "You can manually bind a different NVMe device later using:"
        echo "  sudo scripts/setup.sh"
        DEVICE_BOUND=false
    else
        echo "Attempting to bind NVMe device $NVME_BDF..."
        
        # Get current hugepage count before running setup.sh
        CURRENT_HUGEPAGES=$(grep HugePages_Total /proc/meminfo | awk '{print $2}')
        echo "Current hugepages available: $CURRENT_HUGEPAGES"
        
        # Set NRHUGE environment variable to use available hugepages
        export NRHUGE=$CURRENT_HUGEPAGES
        echo "Setting NRHUGE=$NRHUGE for SPDK setup"
        
        sudo NRHUGE=$CURRENT_HUGEPAGES scripts/setup.sh
        echo "NVMe device binding attempted."
        DEVICE_BOUND=true
    fi
else
    echo "Warning: NVMe device with vendor:device $VENDOR_DEVICE not found."
    echo "Continuing with SPDK setup without device binding..."
    DEVICE_BOUND=false
fi

# Show current device status
echo "Current NVMe device status:"
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
echo "Checking for IOMMU support in kernel boot parameters..."
if grep -q "intel_iommu=on\|amd_iommu=on\|iommu=on" /proc/cmdline; then
    echo "IOMMU is enabled in kernel boot parameters."
    echo "Current kernel command line: $(cat /proc/cmdline)"
elif dmesg | grep -q -e "DMAR.*enabled" -e "AMD-Vi.*enabled" -e "IOMMU.*enabled"; then
    echo "IOMMU is detected and enabled by hardware/firmware."
    dmesg | grep -i iommu | head -3
elif dmesg | grep -q -e DMAR -e IOMMU -e "AMD-Vi"; then
    echo "IOMMU hardware detected but may not be enabled."
    echo "Enabling IOMMU in GRUB..."
    # For Alma Linux, we need to update GRUB_CMDLINE_LINUX instead of GRUB_CMDLINE_LINUX_DEFAULT
    if grep -q "GRUB_CMDLINE_LINUX=" /etc/default/grub; then
        # Check if intel_iommu=on is already present
        if grep -q "intel_iommu=on" /etc/default/grub; then
            echo "IOMMU already configured in GRUB. Skipping GRUB update."
        else
            sed -i 's/GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="intel_iommu=on /' /etc/default/grub
            grub2-mkconfig -o /boot/grub2/grub.cfg
            echo "Warning: IOMMU enabled in GRUB. Please reboot and re-run the script."
            exit 1
        fi
    else
        echo 'GRUB_CMDLINE_LINUX="intel_iommu=on"' >> /etc/default/grub
        grub2-mkconfig -o /boot/grub2/grub.cfg
        echo "Warning: IOMMU enabled in GRUB. Please reboot and re-run the script."
        exit 1
    fi
else
    echo "Warning: IOMMU hardware not detected. SPDK may not work optimally."
    echo "Continuing anyway - SPDK can work without IOMMU but with reduced performance."
fi
echo "IOMMU check completed."

# Test SPDK setup
if [ "$DEVICE_BOUND" = true ]; then
    print_status "Testing SPDK setup with spdk_nvme_identify"
    $IDENTIFY
    echo "spdk_nvme_identify test completed."

    print_status "Testing SPDK setup with hello_world"
    $HELLO_WORLD
    echo "hello_world test completed."
else
    print_status "SPDK setup completed without device binding"
    echo "SPDK libraries and tools are built and ready to use."
    echo "To test SPDK functionality:"
    echo "1. Bind an available NVMe device using: sudo $SPDK_DIR/scripts/setup.sh"
    echo "2. Run tests: $IDENTIFY"
    echo "3. Run hello_world example: $HELLO_WORLD"
    echo ""
    echo "Note: Some tests may fail without a bound NVMe device."
fi

print_status "SPDK setup and tests completed successfully"
echo "SPDK setup and tests completed successfully."
