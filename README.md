# SPDK Installation and Setup Script

This repository contains a Bash script (`spdk_setup.sh`) to automate the installation and setup of [SPDK](https://spdk.io/) (Storage Performance Development Kit) on Ubuntu. The script handles dependency installation, SPDK source code setup, Python virtual environment creation, hugepages configuration, IOMMU and VFIO setup, and builds/tests SPDK with a sample NVMe device.

---

## ⚠️ **Preconditions & User Actions**

- **Run as root:**  
  You must run the script as root (use `sudo`).

- **Edit the script before running:**  
  - **VENDOR_DEVICE:**  
    Update the `VENDOR_DEVICE` variable in the script to match your NVMe device's vendor and device ID.  
    Example:  
    ```bash
    VENDOR_DEVICE="15b7 5011"
    ```
    You can find your device's IDs using `lspci -nn | grep -i nvme`.

  - **[Optional] SPDK_PARENT_DIR, UBUNTU_USER:**  
    Change these variables if your username or home directory is different.

- **System Requirements:**  
  - Ubuntu (tested on 20.04/22.04)
  - Internet access for package installation and git clone
  - Sufficient privileges to modify system configuration (hugepages, IOMMU, VFIO, etc.)

---

## 🚀 **How to Use**

1. **Clone this repository or copy the script to your Ubuntu machine.**

2. **Edit the script:**  
   Open `spdk_setup.sh` and update the variables as described above.

3. **Make the script executable:**
   ```bash
   chmod +x spdk_setup.sh
   ```

4. **Run the script as root:**
   ```bash
   sudo ./spdk_setup.sh
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
