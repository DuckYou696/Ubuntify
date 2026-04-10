# Mac Pro 2013 Ubuntu 24.04 Autoinstall

Automated Ubuntu Server 24.04.4 installation for headless Mac Pro 2013 (MacPro6,1) with Broadcom BCM4360 WiFi.

## Problem

Mac Pro 2013 has no Ethernet port. The Broadcom BCM4360 WiFi requires a proprietary `wl` driver not included in Ubuntu. Without WiFi, the installer can't download packages. Without packages, we can't compile the driver. Circular dependency.

## Solution

**Minimal ISO modification** — insert `autoinstall.yaml` and a `packages/` directory of required debs into the stock Ubuntu 24.04.4 Server ISO. The autoinstall config installs build tools and the Broadcom driver source from those packages, compiles via DKMS against the running kernel, and loads `wl` before network configuration. EFI boot structure is preserved via `xorriso -boot_image any keep`.

```
Boot ISO → early-commands install packages from /cdrom/macpro-pkgs/ → compile wl driver → WiFi connects → autoinstall completes
```

## Files

| File | Purpose |
|------|---------|
| `autoinstall.yaml` | Ubuntu autoinstall configuration |
| `build-iso.sh` | Builds modified ISO from stock Ubuntu ISO + autoinstall.yaml + packages |
| `packages/` | .deb files needed to compile and install WiFi driver (~36 packages, ~75MB) |
| `prereqs/` | Stock Ubuntu 24.04.4 Server ISO (gitignored: `*.iso`) |
| `macpro-monitor/` | Node.js webhook server for headless install monitoring |

## Quick Start

### 1. Build the ISO

```bash
# Place stock Ubuntu 24.04.4 Server ISO in prereqs/
# File: prereqs/ubuntu-24.04.4-live-server-amd64.iso

sudo ./build-iso.sh
```

### 2. Write to USB

```bash
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

Hold Option key → select Ubuntu installer. At the GRUB menu, press `e` to edit the default boot entry and add kernel parameters to the `linux` line:
```
autoinstall ds=nocloud nomodeset amdgpu.si.modeset=0
```

## How It Works

### What's Added to the ISO

Only two things are injected into the stock ISO:

1. `/autoinstall.yaml` — installation configuration
2. `/macpro-pkgs/` — flat directory of ~36 .deb files for driver compilation

### Why Packages Must Be Included

The stock Ubuntu 24.04.4 Server ISO does NOT include:
- `dkms` — Dynamic Kernel Module Support framework
- `broadcom-sta-dkms` — Broadcom WiFi driver source
- `make`, `gcc-13`, `build-essential` — compilation toolchain
- `perl-base`, `kmod`, `fakeroot` — DKMS dependencies

These must be included on the ISO because without WiFi, the installer cannot download them from the internet.

We include all needed debs in `packages/` to avoid fragile dependency resolution against deep ISO pool paths.

### autoinstall.yaml Key Sections

**early-commands** (runs before network config, in the installer environment):
1. Installs kernel headers and modules from `/cdrom/macpro-pkgs/`
2. Installs build toolchain (gcc, make, binutils, libc-dev, etc.)
3. Installs `broadcom-sta-dkms` and `dkms`
4. Compiles `wl.ko` via DKMS against the running kernel (6.8.0-100-generic)
5. Loads driver with `modprobe wl`
6. Verifies module loaded (`lsmod | grep wl`)
7. Waits for WiFi interface to appear (up to 30 seconds)

**network**: Uses `wl0` interface with `match: driver: wl`, connects to configured WiFi

**late-commands** (runs after install, installs into target system):
1. Installs kernel headers, build toolchain, and DKMS into `/target` in 4 dependency-ordered stages
2. Compiles `wl.ko` via DKMS in the target chroot (ensures persistence across reboots)
3. Writes netplan WiFi config for target system
4. Pins kernel version to 6.8.0-100 via `apt-mark hold`
5. Configures mDNS for `macpro-linux.local` hostname resolution
6. Saves install logs to `/var/log/macpro-install/`

**error-commands**: Attempts to load driver and send webhook notification on failure

### AMD FirePro GPU

Mac Pro 2013 uses AMD FirePro D300/D500/D700. The `amdgpu` driver is built into the kernel. No additional GPU driver needed — only the kernel parameters `nomodeset amdgpu.si.modeset=0` in GRUB.

### Storage

The autoinstall targets `/dev/sda` — Mac Pro 2013 uses Apple PCIe SSDs connected via AHCI (not NVMe), so the internal SSD appears as `/dev/sda`.

## Configuration

Edit `autoinstall.yaml` to change:

| Setting | Location | Default |
|---------|----------|---------|
| WiFi SSID | `network.wifis.wl0.access-points` | `ATTj6pXatS` |
| WiFi password | `network.wifis.wl0.access-points` | `j75b39=z?mpg` |
| Hostname | `identity.hostname` | `macpro-linux` |
| Username | `identity.username` | `teja` |
| SSH keys | `ssh.authorized-keys` | 4 keys |
| Webhook URL | `reporting.macpro-monitor.endpoint` | `http://192.168.1.115:8080/webhook` |

## Updating Packages

If you need to refresh the `packages/` directory (e.g., for a different kernel version):

```bash
# Download packages from Ubuntu packages archive
# For kernel 6.8.0-100-generic, you need:
# - linux-headers-6.8.0-100 (all + generic)
# - broadcom-sta-dkms, dkms
# - gcc-13, make, build-essential, and all build dependencies
```

## Troubleshooting

### Driver won't compile
```bash
dmesg | grep -i 'dkms\|wl\|broadcom'
cat /run/macpro.log
```

### WiFi doesn't connect
```bash
dmesg | grep wl
ip link show | grep wl
lsmod | grep wl
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