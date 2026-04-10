# Mac Pro 2013 — Headless Ubuntu Deployment Plan

## Goal

Deploy Ubuntu 24.04.4 Server onto a Mac Pro 2013 (MacPro6,1) with **zero physical access**, using SSH from a MacBook on the same network. The Mac Pro is currently running macOS 12.7.6 and is only accessible via WiFi SSH.

## Constraints

- No keyboard, monitor, or mouse — all operations remote via SSH
- Cannot disable SIP — must use Apple's `bless` command for boot control
- WiFi-only network — must compile Broadcom `wl` driver before any network access
- No NetBoot — requires macOS Server + BSDP, not feasible
- Unrecoverable if installer fails — no physical access to recover; must test in VirtualBox first
- **Cannot `dd` ISO to partition** — Mac EFI expects FAT32 ESP with `/EFI/BOOT/BOOTX64.EFI`, not ISO9660

## Current State

### What Works
- ✅ `autoinstall.yaml` — complete configuration with WiFi driver compilation, SSH, storage, error logging
- ✅ `build-iso.sh` — builds modified ISO with autoinstall.yaml, cidata/, packages, and pre-baked GRUB config
- ✅ `packages/` — 36 .deb files for offline driver compilation
- ✅ `macpro-monitor/` — webhook server for installation monitoring
- ✅ `prepare-headless-deploy.sh` — macOS-side script for zero-physical-access deployment via bless
- ✅ SSH server in installer — starts in `early-commands` after WiFi driver compilation
- ✅ Pre-baked GRUB config — auto-selects autoinstall after 3 seconds, no keyboard input needed
- ✅ `cidata/` NoCloud structure — for `ds=nocloud` autoinstall discovery
- ✅ USB boot method — GRUB auto-selects autoinstall entry

### What's Missing
- ⬜ VirtualBox validation of the full flow
- ⬜ Real hardware test

## Deployment Flow

```
┌─────────────────────────────────────────────────────────┐
│ PHASE 0: Preparation (MacBook)                         │
│                                                         │
│ 1. Build modified ISO: sudo ./build-iso.sh              │
│ 2. Start webhook monitor: ./macpro-monitor/start.sh     │
│ 3. SCP ISO to Mac Pro: scp ubuntu-macpro.iso macpro:~  │
└────────────────────────────┬────────────────────────────┘
                             │ SSH
                             ▼
┌─────────────────────────────────────────────────────────┐
│ PHASE 1: Disk Preparation (macOS on Mac Pro)            │
│                                                         │
│ 1. Check partition layout: diskutil list                │
│ 2. Verify APFS snapshots: diskutil apfs list            │
│ 3. Shrink APFS: diskutil apfs resizeContainer ...       │
│ 4. Create FAT32 ESP: diskutil addPartition ... FAT32    │
│ 5. Extract ISO to ESP: mount ISO → copy files           │
│ 6. Write GRUB config with autoinstall params            │
│ 7. Write cidata/ for ds=nocloud discovery               │
│ 8. Set boot device: bless --setBoot --mount ESP         │
│ 9. Reboot: shutdown -r now                              │
└────────────────────────────┬────────────────────────────┘
                             │ Reboot
                             ▼
┌─────────────────────────────────────────────────────────┐
│ PHASE 2: Ubuntu Installer (autoinstall)                 │
│                                                         │
│ 1. Mac EFI boots from ESP → GRUB → Linux kernel        │
│ 2. early-commands: compile wl driver from /cdrom/...    │
│ 3. early-commands: start SSH server for debug access    │
│ 4. WiFi connects via wl driver                          │
│ 5. autoinstall partitions /dev/sda                      │
│ 6. late-commands: install driver into target system     │
│ 7. late-commands: write netplan config                  │
│ 8. System installed, reboots into Ubuntu                │
│                                                         │
│ Monitoring: webhook → macpro-monitor on MacBook          │
│ Debug: SSH into installer via WiFi (if driver works)    │
└────────────────────────────┬────────────────────────────┘
                             │ Reboot
                             ▼
┌─────────────────────────────────────────────────────────┐
│ PHASE 3: Installed Ubuntu                               │
│                                                         │
│ 1. Boot from internal SSD                               │
│ 2. wl driver loads (via /etc/modules + DKMS)            │
│ 3. WiFi connects via netplan                            │
│ 4. SSH accessible: ssh teja@macpro-linux.local          │
│ 5. Verify: dmesg, lsmod, ip addr, systemctl            │
└─────────────────────────────────────────────────────────┘
```

## Implementation Steps

### Step 1: ✅ Create `prepare-headless-deploy.sh`

**Status**: Complete — see `prepare-headless-deploy.sh`

The script runs via SSH on the Mac Pro and:
1. Verifies current disk layout and free space
2. Shrinks macOS APFS container to ~100GB
3. Creates a 2GB FAT32 ESP partition
4. Mounts the built ISO and extracts all contents to ESP (EFI boot files, casper, packages, cidata, pool, dists, .disk)
5. Writes pre-baked GRUB config with `autoinstall ds=nocloud nomodeset amdgpu.si.modeset=0`
6. Verifies all required ESP files before proceeding
7. Runs `bless --setBoot --mount <esp>` to set next boot device
8. Confirms and reboots

### Step 2: ✅ Update `autoinstall.yaml` for SSH during Install

**Status**: Complete — `early-commands` now starts SSH server after WiFi driver compilation

The autoinstall config tries `apt-get install openssh-server` from the ISO pool first, falls back to `packages/openssh-server_*.deb` if available, then starts sshd with `mkdir -p /run/sshd && /usr/sbin/sshd -D -e &`.

### Step 3: ✅ Create GRUB config for ESP

**Status**: Complete — `build-iso.sh` now injects `/EFI/boot/grub.cfg` and `/boot/grub/grub.cfg`

```cfg
set default=0
set timeout=3

menuentry "Ubuntu Server 24.04 Autoinstall (Mac Pro 2013)" {
    set gfxpayload=keep
    linux /casper/vmlinuz autoinstall ds=nocloud nomodeset amdgpu.si.modeset=0 ---
    initrd /casper/initrd
}

menuentry "Ubuntu Server 24.04 (Manual Install)" {
    set gfxpayload=keep
    linux /casper/vmlinuz nomodeset amdgpu.si.modeset=0 ---
    initrd /casper/initrd
}
```

### Step 4: ✅ Verify cidata/ Structure

**Status**: Complete — `build-iso.sh` now creates `/cidata/` with `user-data`, `meta-data`, and `vendor-data`

The NoCloud datasource is covered by two methods:
1. `/autoinstall.yaml` at ISO root — found regardless of `ds=nocloud`
2. `/cidata/` on ISO — provides `ds=nocloud` discovery for ESP boot

Autoinstall config discovery precedence: kernel cmdline > root of install system > cloud-config (NoCloud) > root of install medium (ISO). Our `/autoinstall.yaml` at ISO root is found via method 4.

### Step 5: ✅ Update `build-iso.sh`

**Status**: Complete — now injects autoinstall.yaml, cidata/, packages/, and GRUB config

The build script now maps 4 things into the ISO:
- `/autoinstall.yaml` — installation config
- `/cidata/` — NoCloud datasource (user-data, meta-data, vendor-data)
- `/macpro-pkgs/` — driver compilation packages
- `/EFI/boot/grub.cfg` and `/boot/grub/grub.cfg` — pre-baked GRUB config with autoinstall entry

### Step 6: VirtualBox Validation

Before touching real hardware, validate in VirtualBox:
1. Extract ISO to a virtual disk ESP using the same process as `prepare-headless-deploy.sh`
2. Set VirtualBox to EFI boot from that disk
3. Verify: autoinstall starts, driver compiles, installation completes
4. Monitor via serial console and webhook

### Step 7: Test on Real Hardware

Only after VirtualBox validation passes:
1. SSH into Mac Pro from MacBook
2. Run `prepare-headless-deploy.sh`
3. Monitor via webhook on MacBook
4. Wait for installation to complete
5. SSH into installed Ubuntu: `ssh teja@macpro-linux.local`

## Open Questions

1. **ESP size**: `prepare-headless-deploy.sh` uses 2GB ESP. Casper directory is ~850MB. This should be sufficient but needs VirtualBox validation.

2. **nocloud datasource from ESP**: Autoinstall finds `/autoinstall.yaml` at ISO root regardless of `ds=nocloud`. The `/cidata/` structure provides a secondary discovery path. Both are now injected by `build-iso.sh` and extracted to ESP by `prepare-headless-deploy.sh`.

3. **bless persistence**: `bless --setBoot` sets the NVRAM boot variable. On successful Ubuntu install, the installed system's GRUB takes over. On failure, boot into macOS requires resetting NVRAM or intervention from Target Disk Mode.

4. **APFS resize limits**: macOS 12.7.6 can typically be shrunk to ~40-60GB depending on installed software. The script targets 100GB for macOS.

5. **installer SSH access**: ✅ Resolved — `early-commands` now starts sshd after WiFi driver compilation. Uses `apt-get install openssh-server` from the ISO pool, with fallback to `packages/openssh-server_*.deb`.

## Failure Recovery Plan

| Failure Point | Detection | Recovery |
|--------------|-----------|----------|
| APFS shrink fails | Script exits with error | No change made, macOS still intact |
| ESP creation fails | Script exits before bless | Delete empty partition, no harm |
| bless fails | Script exits before reboot | No boot device changed, macOS boots normally |
| Installer doesn't start | No webhook after 10 min | Target Disk Mode from MacBook via Thunderbolt |
| WiFi driver won't compile | Webhook: early-commands failure | SSH into installer (if sshd started) or Target Disk Mode |
| Installation completes but no SSH | No SSH after 30 min | Check DHCP table on router, try mDNS `.local` |
| Complete failure (unreachable) | No contact after 30 min | Physical access required (last resort) |

## Key Reference: AsahiLinux bless Pattern

AsahiLinux (Linux on Apple Silicon Macs) uses this exact bless approach:
```bash
bless --setBoot --mount "$system_dir"
```
Where `$system_dir` is a mounted FAT32 ESP containing a valid EFI boot structure. This is production-proven on Mac hardware.