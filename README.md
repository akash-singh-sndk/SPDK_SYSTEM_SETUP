# SPDK Installation and Setup Script

This repository contains a Bash script (`spdk_setup.sh`) to automate the installation and setup of [SPDK](https://spdk.io/) (Storage Performance Development Kit) on Ubuntu. The script handles dependency installation, SPDK source code setup, Python virtual environment creation, hugepages configuration, IOMMU and VFIO setup, and builds/tests SPDK with a sample NVMe device.

---

## ⚠️ **Preconditions & User Actions**

- **Run as root:**  
  You must run the script as root (use `sudo`).

- **Edit the script before running:**  
  - **Config:**  
    Update the `SPDK_PARENT_DIR`, `SPDK_DIR`, `ALMA_USER`, `VENDOR_DEVICE` & `BDF` variable in the script to match your NVMe device's vendor and device BDF.  
    Example:  
    ```bash
    SPDK_PARENT_DIR="/home/aks/AKS"
    SPDK_DIR="/home/aks/AKS/spdk"
    ALMA_USER="aks"
    NVME_BDF="0000:03:00.0"
    VENDOR_DEVICE="15b7:5045"
    ```
    You can find your `VENDOR_DEVICE` IDs using `lspci -nn | grep "Non-Volatile memory controller"` & for `BDF` run `sudo nvme list`.

- **System Requirements:**  
  - Ubuntu (tested on 20.04/22.04) and Alma Linux (tested on v10.0/v9.0)
  - Internet access for package installation and git clone
  - Sufficient privileges to modify system configuration (hugepages, IOMMU, VFIO, etc.)

---

# IMPORTANT NOTE FOR VIRTUAL MACHINE USERS

## NVMe Configuration Requirements for VMs

**⚠️ CRITICAL REQUIREMENT: If you are running this SPDK setup script on a Virtual Machine (VM), you MUST configure your VM with at least 2 separate NVMe hard disks before running the script.**

### VM NVMe Disk Configuration:

1. **Primary NVMe Disk (Disk 1):**
   - **Purpose**: Operating System installation
   - **Size**: Minimum 20GB (recommended 40GB+)
   - **Usage**: Contains Alma Linux OS, root filesystem, swap, and boot partitions
   - **Status**: Will remain bound to the OS and cannot be used for SPDK

2. **Secondary NVMe Disk (Disk 2):**
   - **Purpose**: SPDK configuration and testing
   - **Size**: Minimum 4GB (recommended 10GB+)
   - **Usage**: Will be bound to SPDK for high-performance storage testing
   - **Status**: Must be completely unused (no partitions, no filesystem)

### Why This Configuration is Required:

- **SPDK requires exclusive access** to NVMe devices for userspace drivers
- **The script automatically detects and protects** the OS boot drive from SPDK binding
- **Without a second NVMe disk**, SPDK will have no devices to bind to for testing
- **Virtual environments** typically don't expose multiple NVMe devices by default

### VM Platform Configuration:

#### VMware vSphere/Workstation:
1. Add a second virtual disk
2. Set disk type to "NVMe"
3. Ensure both disks use NVMe controller type

#### KVM/QEMU:
1. Add second disk with `-drive` parameter
2. Use `if=none` and `nvme` device type
3. Configure separate NVMe namespaces

#### VirtualBox:
1. Add second SATA/NVMe disk in VM settings
2. Ensure VM has NVMe controller enabled
3. Configure storage controller properly

### Verification Before Running Script:

Check your NVMe devices with:
```bash
nvme list
```

You should see at least 2 NVMe devices before proceeding with the script.

### Script Behavior:
- **Automatic Detection**: Script will identify the boot device and skip it
- **Safe Binding**: Only unused NVMe devices will be bound to SPDK
- **Graceful Fallback**: If only one NVMe device is found, script will complete setup but skip device binding tests

**💡 TIP: If you only have one NVMe disk, the script will build SPDK successfully but you'll need to manually add a second NVMe disk later for full functionality testing.**

## 🚀 **How to Use**

1. **Clone this repository or copy the script to your Ubuntu machine.**

2. **Edit the script:**  
   Open `<spdk_setup_script>.sh` and update the variables as described above.

3. **Make the script executable:**
   ```bash
   chmod +x <spdk_setup_script>.sh
   ```

4. **Run the script as root:**
   ```bash
   sudo ./<spdk_setup_script>.sh
   ```

5. **Follow any reboot instructions:**  
   The script may prompt you to reboot if kernel parameters or limits are changed. After reboot, re-run the script.

---

## 📝 **What the Script Does**

- Installs all required dependencies for SPDK and DPDK.
- Clones the SPDK repository (if not already present).
- Sets up a Python virtual environment and installs `pyelftools`.
- Configures hugepages and memlock limits.
- Ensures IOMMU is enabled and the NVMe device is in an IOMMU group.
- Loads the `vfio-pci` kernel module and binds your NVMe device to it.
- Builds SPDK and DPDK.
- Runs SPDK sample applications (`spdk_nvme_identify` and `hello_world`) to verify the setup.

---

## 🛠️ **Troubleshooting**

- **Dependency errors:**  
  Ensure your system has internet access and the correct Ubuntu repositories enabled.

- **Device binding errors:**  
  Double-check `VENDOR_DEVICE` and `NVME_BDF` values.

- **Permission errors:**  
  Always run the script as root.

- **Reboot required:**  
  If the script updates kernel parameters or limits, reboot and re-run the script.

---

## 📄 **References**

- [SPDK Documentation](https://spdk.io/doc/)
- [SPDK GitHub](https://github.com/spdk/spdk)

---

## 📢 **Disclaimer**

This script modifies system configuration (kernel modules, hugepages, device bindings, etc.). Use with caution and only on test or development systems unless you fully understand the changes being made.

---
