# Mac Pro 2013 Ubuntu 24.04 — Headless Autoinstall

Automated Ubuntu Server 24.04.4 deployment for a headless Mac Pro 2013 (MacPro6,1) with Broadcom BCM4360 WiFi, installed entirely over SSH with zero physical access.

## Specifications

### Hardware
- **Model**: Mac Pro 2013 (MacPro6,1), trash can design
- **GPU**: AMD FirePro D300/D500/D700 (amdgpu driver, `nomodeset amdgpu.si.modeset=0`)
- **WiFi**: Broadcom BCM4360 — requires proprietary `wl` driver, not in Ubuntu
- **Storage**: Apple PCIe SSD via AHCI → `/dev/sda` (not NVMe)
- **No Ethernet port** — WiFi is the only network path

### Operational Constraints
- **Zero physical access** — no keyboard, monitor, or mouse available
- **macOS 12.7.6 running** — accessible only via SSH
- **Cannot disable SIP** — stuck with Apple's default bootloader
- **Must wipe macOS** — full disk install, no dual-boot
- **SSH access required during install** — need to debug if anything goes wrong
- **MacBook available on network** — can serve as monitoring/webhook endpoint and fallback NetBoot host

### Circular Dependency Problem
Mac Pro has no Ethernet. Broadcom BCM4360 WiFi requires a proprietary `wl` driver not included in Ubuntu. Without WiFi, the installer can't download packages. Without packages, we can't compile the driver. The `packages/` directory on the ISO breaks this cycle.

## Solution Overview

**Minimal ISO modification + remote boot via `bless`**:

1. Build a modified Ubuntu Server ISO with `autoinstall.yaml` and a `packages/` directory injected
2. Extract ISO contents to an EFI System Partition on the Mac Pro's internal disk (via SSH)
3. Use `bless --setBoot` via SSH to set the ESP as next boot device
4. Reboot → Mac Pro boots into Ubuntu installer from internal disk → autoinstall runs headlessly

```
SSH into macOS → repartition disk → extract ISO to ESP → bless --setBoot → reboot → autoinstall completes
```

The autoinstall config compiles the WiFi driver, starts SSH for remote debugging, and runs headlessly. The `autoinstall` kernel parameter bypasses the confirmation prompt (required for zero-touch deployment). SSH is available during install at `installer@<ip>` or via the configured SSH keys.

## Files

| File | Purpose |
|------|---------|
| `autoinstall.yaml` | Ubuntu autoinstall configuration — WiFi driver compilation, SSH, storage layout |
| `build-iso.sh` | Builds modified ISO with autoinstall.yaml + packages + GRUB config + cidata |
| `packages/` | .deb files needed to compile and install WiFi driver (~36 packages, ~75MB) |
| `prepare-headless-deploy.sh` | macOS-side script: repartition, extract ISO to ESP, bless, reboot (zero physical access) |
| `prereqs/` | Stock Ubuntu 24.04.4 Server ISO (`*.iso` gitignored) |
| `macpro-monitor/` | Node.js webhook server for headless install monitoring |
| `PLAN.md` | Implementation plan for the full headless deployment workflow |

## Quick Start

### USB Boot (Requires Physical Access)

```bash
# 1. Build the ISO (place stock ISO in prereqs/ first)
sudo ./build-iso.sh

# 2. Write to USB
diskutil list  # find your USB drive
diskutil unmountDisk /dev/diskN
sudo dd if=ubuntu-macpro.iso of=/dev/diskN bs=1m

# 3. Boot from USB — GRUB auto-selects autoinstall after 3 seconds
# No manual keyboard input needed (params are pre-baked in GRUB config)
```

### Headless Deploy (Zero Physical Access)

```bash
# 1. Build the ISO and transfer to Mac Pro
sudo ./build-iso.sh
scp ubuntu-macpro.iso macpro:~

# 2. Start webhook monitor on MacBook
cd macpro-monitor && ./start.sh

# 3. SSH into Mac Pro and run the deploy script
ssh macpro
sudo ./prepare-headless-deploy.sh ~/ubuntu-macpro.iso

# 4. Monitor installation via webhook; SSH into installer for debugging
```

### Start Webhook Monitor (optional but recommended)

```bash
cd macpro-monitor && ./start.sh
# Webhook at http://<your-ip>:8080/webhook
```

## How It Works

### What's Added to the ISO

Four things are injected into the stock ISO:

1. `/autoinstall.yaml` — installation configuration
2. `/cidata/` — NoCloud datasource (`user-data`, `meta-data`, `vendor-data`) for `ds=nocloud` discovery
3. `/macpro-pkgs/` — flat directory of ~36 .deb files for driver compilation
4. `/EFI/boot/grub.cfg` and `/boot/grub/grub.cfg` — GRUB config with pre-baked `autoinstall ds=nocloud nomodeset amdgpu.si.modeset=0` kernel parameters (no manual keyboard input needed)

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
6. Verifies module loaded (`lsmod | grep wl`) and logs result
7. Waits for WiFi interface to appear (up to 30 seconds, checks `wl[pw]*` and `wlan*` patterns)
8. Starts SSH server for remote debugging via `apt-get install openssh-server`

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

## Remote Deployment (Zero Physical Access)

For the headless scenario, the USB boot method above requires physical access. The remote deployment approach uses macOS's `bless` command to boot into the installer from SSH:

### Feasibility

| Approach | Feasible? | Notes |
|----------|-----------|-------|
| Repartition + `bless` via SSH | ✅ | `diskutil resizeVolume` + `bless --setBoot` works from SSH |
| `dd` ISO to partition | ❌ | Mac EFI expects FAT32 ESP with `/EFI/BOOT/BOOTX64.EFI`, not ISO9660 |
| Extract ISO to ESP + `bless` | ✅ | AsahiLinux uses this exact pattern for Mac Linux installs |
| NetBoot/NetInstall | ❌ | Requires macOS Server + BSDP protocol; Ubuntu doesn't speak BSDP |
| SSH during installer | ✅ | Must start sshd in `early-commands` before WiFi driver compilation |
| Target Disk Mode | ⚠️ Fallback | Needs brief physical access |

### Remote Deployment Flow

```
1. SSH into macOS
2. Transfer ISO to Mac Pro via scp
3. Shrink APFS partition: diskutil resizeVolume
4. Create partitions: ESP (FAT32) + root (ext4 placeholder)
5. Mount ISO, extract EFI boot files + casper + autoinstall.yaml + packages to ESP
6. Modify GRUB config to include: autoinstall ds=nocloud nomodeset amdgpu.si.modeset=0
7. bless --setBoot --mount /Volumes/ESP
8. Reboot → autoinstall runs headlessly
9. Monitor via webhook + SSH into installer environment
```

See `PLAN.md` for the detailed implementation plan.

### Risk: No Recovery Without Physical Access

If the installer fails or the partition setup is wrong, the Mac Pro becomes unreachable — no SSH, no monitor, no keyboard. Mitigations:

- **Webhook monitoring** — receive status updates at each autoinstall stage
- **SSH into installer** — debug during installation before target system is written
- **Test in VirtualBox first** — validate the entire flow before touching real hardware
- **Fallback: Target Disk Mode** — MacBook on network + Thunderbolt cable for emergency recovery

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