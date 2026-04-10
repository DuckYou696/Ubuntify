# Mac Pro 2013 Ubuntu 24.04 Autoinstall

Automated Ubuntu Server 24.04.4 installation for headless Mac Pro 2013 (MacPro6,1) with Broadcom BCM4360 WiFi.

## Problem

Mac Pro 2013 has no Ethernet port. The Broadcom BCM4360 WiFi requires a proprietary `wl` driver not included in Ubuntu. Without WiFi, the installer can't download packages. Without packages, we can't compile the driver. Circular dependency.

## Solution

**Minimal ISO modification** — only insert `autoinstall.yaml` into the stock Ubuntu 24.04.4 Server ISO. The autoinstall config leverages packages already present in the ISO's pool to compile and install the WiFi driver during installation. EFI boot structure is preserved via `xorriso -boot_image any keep`.

```
Boot ISO → early-commands compile wl driver from ISO pool → WiFi connects → autoinstall completes
```

## Files

| File | Purpose |
|------|---------|
| `autoinstall.yaml` | Ubuntu autoinstall configuration (the only file added to ISO) |
| `build-iso.sh` | Builds modified ISO from stock Ubuntu ISO + autoinstall.yaml |
| `macpro-monitor/` | Node.js webhook server for headless install monitoring |
| `prepare_ubuntu_install_final.sh` | Legacy macOS-side prep script (references old initramfs approach) |

## Quick Start

### 1. Build the ISO

```bash
# Place stock Ubuntu 24.04.4 Server ISO in prereqs/
# File: prereqs/ubuntu-24.04.4-live-server-amd64.iso

sudo ./build-iso.sh
```

### 2. Write to USB

```bash
# On macOS:
diskutil list  # find your USB drive
diskutil unmountDisk /dev/diskN
sudo dd if=ubuntu-macpro.iso of=/dev/diskN bs=1m
```

### 3. Monitor Installation (optional)

```bash
cd macpro-monitor && ./start.sh
# Webhook at http://<your-ip>:8080/webhook
```

### 4. Boot Mac Pro

Hold Option key → select Ubuntu installer. GRUB will auto-select the autoinstall entry after 30s.

**Important:** If booting manually, add kernel parameters:
```
autoinstall nomodeset amdgpu.si.modeset=0
```

## How It Works

### autoinstall.yaml Key Sections

**early-commands** (runs before network config):
- Installs kernel headers and build tools from `/cdrom/pool/` (packages on the ISO)
- Compiles Broadcom `wl` driver via DKMS against running kernel
- Loads driver with `modprobe wl`
- Waits for WiFi interface to appear

**network**: Matches any interface with `driver: wl`, connects to configured WiFi

**late-commands** (runs after install):
- Installs DKMS driver into target system (persists across reboots)
- Writes netplan WiFi config for target system
- Pins kernel version to prevent breakage
- Configures mDNS for `macpro-linux.local` hostname resolution

**error-commands**: Attempts to load driver and send webhook notification on failure

### Why This Works Without Network

The Ubuntu 24.04.4 Server ISO already includes in its pool:
- `broadcom-sta-dkms` — Broadcom driver source
- `linux-headers-6.8.0-100*` — matching kernel headers
- `dkms`, `make`, `gcc-13`, `binutils`, `libc6-dev` — build toolchain
- `wpasupplicant`, `avahi-daemon` — network utilities

Since subiquity mounts the ISO at `/cdrom`, all packages are available via `dpkg -i /cdrom/pool/...`.

### AMD FirePro GPU

Mac Pro 2013 uses AMD FirePro D300/D500/D700. The `amdgpu` driver is built into the kernel. No additional GPU driver compilation needed — only the kernel parameters `nomodeset amdgpu.si.modeset=0` in GRUB.

## Configuration

Edit `autoinstall.yaml` to change:

| Setting | Location | Default |
|---------|----------|---------|
| WiFi SSID | `network.wifis` | `ATTj6pXatS` |
| WiFi password | `network.wifis` | `j75b39=z?mpg` |
| Hostname | `identity.hostname` | `macpro-linux` |
| Username | `identity.username` | `teja` |
| SSH keys | `ssh.authorized-keys` | 4 keys |
| Webhook URL | `reporting` | `http://192.168.1.115:8080/webhook` |

## Troubleshooting

### Driver won't compile
Check that ISO kernel matches headers:
```bash
strings /cdrom/casper/vmlinuz | grep "6.8.0-100"
ls /cdrom/pool/main/l/linux/linux-headers-6.8.0-100*
```

### WiFi doesn't connect
```bash
dmesg | grep wl
ip link show | grep wl
```

### Can't SSH after install
```bash
ssh teja@macpro-linux.local
# Or try IP directly (check router DHCP table)
```

### Kernel updates break WiFi
Kernel is pinned to 6.8.0-100 via `apt-mark hold`. If you must update, recompile the driver:
```bash
sudo dkms remove broadcom-sta/6.30.223.271 -k <new-kernel>
sudo dkms install broadcom-sta/6.30.223.271 -k <new-kernel>
```