# Post-Install Operations — Agent Execution Guide

This document provides step-by-step procedures for two post-install operations on the headless Mac Pro 2013 Ubuntu system. It is designed for **LLM agent execution** — every step is explicit, every decision point is documented, and every failure mode has a rollback path.

> **Machine context**: Mac Pro 2013 (MacPro6,1), Ubuntu 24.04 LTS, zero physical access, WiFi-only networking (Broadcom BCM4360 via proprietary `wl` driver). Disk is `/dev/sda` (Apple PCIe SSD via AHCI). The `wl` driver is compiled via DKMS with 6 compatibility patches applied to `/usr/src/broadcom-sta-6.30.223.271/`. Kernel is pinned to `6.8.0-100-generic`.

---

## Operation 1: Erase macOS and Expand Ubuntu to Full Disk

### Overview

The current dual-boot layout preserves macOS on separate APFS partitions. This operation:
1. Identifies and deletes all macOS/APFS partitions
2. Expands the Ubuntu root (`/`) partition into the freed space
3. Updates GRUB and fstab
4. Removes the macOS boot entry from GRUB and `efibootmgr`
5. Verifies the system still boots and WiFi works

### DANGER SUMMARY

| Risk | Consequence | Mitigation |
|------|-------------|------------|
| Deleting the wrong partition | Data loss, unbootable system | Step 1 has explicit partition identification with verification prompts |
| Root partition resize fails | Root filesystem corruption | Step 3 reads current state first, uses `growpart` + `resize2fs` (safe, in-place) |
| GRUB misconfiguration after partition deletion | Unbootable system | Step 4 regenerates GRUB, Step 5 verifies before declaring success |
| Boot-recovery partition accidentally deleted | No fallback | EFI System Partition (ESP) is never touched — it's a separate partition |

### Prerequisites

Before executing this operation, verify:

```bash
# You have active SSH access RIGHT NOW
whoami  # must succeed
ping -c 3 google.com  # WiFi must be working
uname -r  # record current kernel
dkms status broadcom-sta  # record DKMS status
```

**If any prerequisite fails, DO NOT proceed.**

---

### Step 1: Identify the Current Partition Layout

```bash
# List all partitions with types and labels
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT /dev/sda
echo "---"
# Show GPT partition details
sudo sgdisk -p /dev/sda
echo "---"
# Identify which partitions belong to macOS vs Ubuntu
# macOS partitions: FSTYPE=apfs, or partition type GUID C12A7328-F81F-11D2-BA4B-00A0C93EC93B (EFI)
#   or 426F6F74-0000-11AA-AA11-00306543ECAC (Apple Boot / Recovery HD)
#   or 7C3457EF-0000-11AA-AA11-00306543ECAC (Apple APFS)
# Ubuntu partitions: the ones currently MOUNTED (/ and /boot)
```

**Agent MUST read the output and classify every partition as either macOS or Ubuntu before proceeding.** Classification rules:

| Partition Type | Classification | Action |
|---------------|----------------|--------|
| Mounted at `/` | Ubuntu root | **DO NOT DELETE** |
| Mounted at `/boot` | Ubuntu boot | **DO NOT DELETE** |
| Mounted at `/boot/efi` | EFI System Partition | **DO NOT DELETE** — shared by both OSes |
| FSTYPE contains `apfs` | macOS | Target for deletion |
| TYPE GUID `7C3457EF-...` | Apple APFS container | Target for deletion |
| TYPE GUID `426F6F74-...` | Apple Boot/Recovery | Target for deletion |
| LABEL contains `Macintosh` or `Recovery` | macOS | Target for deletion |
| Swap partition (FSTYPE=`swap`) | Ubuntu | **DO NOT DELETE** |

**Record the partition numbers to delete. You will need them in Step 2.**

### Step 2: Delete macOS Partitions

**Before deleting, create a backup of the partition table:**

```bash
# Save current GPT partition table (for emergency recovery)
sudo sgdisk -b /tmp/gpt-backup-$(date +%Y%m%d%H%M%S).bin /dev/sda
echo "GPT backup saved. In emergency: sgdisk -l <backup-file> /dev/sda"
```

**Delete each identified macOS partition by number:**

```bash
# Replace N1, N2, N3 with the actual partition numbers from Step 1
# DELETE ONE AT A TIME — verify each succeeds
# EXAMPLE (adjust partition numbers based on Step 1):
# sudo sgdisk -d 3 /dev/sda    # Delete partition 3 (macOS APFS)
# sudo sgdisk -d 4 /dev/sda    # Delete partition 4 (Recovery HD)
# etc.

# IMPORTANT: After each deletion, partition NUMBERS may shift.
# Re-read the partition table after EACH deletion:
# sudo sgdisk -p /dev/sda
# Then identify the NEXT macOS partition by its new number.
```

**Verification after all deletions:**

```bash
sudo sgdisk -p /dev/sda
# Confirm: no APFS partitions remain, no Apple Boot partitions remain
# Confirm: Ubuntu partitions (/, /boot, /boot/efi) still exist
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT /dev/sda
# Confirm: / and /boot are still mounted and accessible
df -h / /boot
# Confirm: filesystem still writable
touch /tmp/write-test && rm /tmp/write-test
```

**If verification fails at any point, STOP. Do NOT proceed.** The system may need a reboot to re-read the partition table, but only if all critical partitions are intact.

### Step 3: Expand the Root Partition into Free Space

The freed space from deleted macOS partitions is now unallocated. Expand the root (`/`) partition to consume it.

```bash
# Step 3a: Identify the root partition number
ROOT_PART=$(lsblk -no NAME,MOUNTPOINT /dev/sda | grep ' /$' | grep -oE '[0-9]+')
ROOT_DISK="/dev/sda"
ROOT_DEVICE="${ROOT_DISK}${ROOT_PART}"  # e.g., /dev/sda5

echo "Root partition: ${ROOT_DEVICE} (partition ${ROOT_PART})"
lsblk "$ROOT_DEVICE"
df -h /

# Step 3b: Check that free space exists AFTER the root partition
# (partitions between root and free space would block resize)
sudo parted /dev/sda print free
# Look for "Free Space" entries after the root partition
# If free space is NOT adjacent to the root partition, you must
# rearrange partitions first (advanced — consult the user)

# Step 3c: Use growpart to expand the partition (safe, in-place)
# growpart is installed by default on Ubuntu Server
sudo growpart /dev/sda "$ROOT_PART"

# Step 3d: Resize the ext4 filesystem to fill the expanded partition
sudo resize2fs "${ROOT_DEVICE}"

# Step 3e: Verify
df -h /
# The "Size" column should now reflect the full available disk space
# (minus /boot, /boot/efi, and any remaining partitions)
```

**Troubleshooting:**

| Error | Cause | Fix |
|-------|-------|-----|
| `growpart` fails with "no free space" | Free space not adjacent to root partition | Must move partitions — ask user before proceeding |
| `resize2fs` fails | Partition wasn't actually expanded | `sudo partprobe /dev/sda` then retry `resize2fs` |
| `growpart` not found | Not installed | `sudo apt-get install cloud-guest-utils` — but sources may be commented out, so uncomment first |

### Step 4: Update GRUB and Remove macOS Boot Entries

```bash
# Step 4a: Remove the macOS GRUB menu entry (no longer needed)
sudo rm -f /etc/grub.d/40_macos

# Step 4b: Remove fwsetup entry if it's the only macOS boot method
# Check if 40_macos was the only custom entry:
ls /etc/grub.d/

# Step 4c: Update GRUB configuration
sudo update-grub

# Step 4d: Remove macOS from EFI boot manager
export LIBEFIVAR_OPS=efivarfs  # Workaround for Apple EFI 1.1 bug
# List all boot entries
efibootmgr
# Find the macOS boot entry number (Boot80, Boot81, or any "macOS"/"Apple" entry)
# Delete it:
# MACOS_ENTRY=$(efibootmgr | grep -i "macos\|apple" | head -1 | grep -oE 'Boot[0-9A-F]+' | sed 's/Boot//')
# if [ -n "$MACOS_ENTRY" ]; then
#   sudo efibootmgr --delete-bootnum --bootnum "$MACOS_ENTRY"
#   echo "Removed macOS boot entry: $MACOS_ENTRY"
# else
#   echo "No macOS boot entry found in EFI — nothing to remove"
# fi

# Step 4e: Remove the boot-macos script (no longer needed)
sudo rm -f /usr/local/bin/boot-macos

# Step 4f: Verify GRUB config no longer references macOS
grep -i "macos\|apple\|fwsetup" /boot/grub/grub.cfg && echo "WARNING: macOS references still in GRUB" || echo "GRUB clean — no macOS references"
```

### Step 5: Verify and Reboot

```bash
# Step 5a: Verify the system is still functional before reboot
echo "=== Pre-reboot verification ==="
uname -r
lsmod | grep wl  # WiFi driver loaded
ping -c 3 google.com  # WiFi working
df -h / /boot /boot/efi  # All filesystems mounted
cat /etc/fstab  # fstab intact
ls /boot/vmlinuz-*  # Kernel still present
sudo grub-editenv list 2>/dev/null || echo "GRUB env block OK"
echo "=== Verification complete ==="

# Step 5b: Reboot
sudo reboot
```

**After reboot, from your MacBook/other machine:**

```bash
# Wait 60-90 seconds, then attempt SSH
ssh macpro-linux

# Verify:
uname -r  # Kernel
lsmod | grep wl  # WiFi driver
ping -c 3 google.com  # Network
df -h /  # Full disk now available
lsblk /dev/sda  # Only Ubuntu partitions remain
```

### Step 6 (Optional): Extend Swap

If the root partition was significantly expanded and you want swap space:

```bash
# Check if swap exists
swapon --show

# If no swap, create a swapfile on the expanded root filesystem:
sudo fallocate -l 8G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile

# Make it persistent:
grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab

# Verify:
free -h
```

### Rollback for Operation 1

**Once macOS partitions are deleted (Step 2), there is NO rollback.** macOS data is gone. The GPT backup saved in Step 2 only restores the partition table entries, not the data.

The only reversible step is the partition expansion — if `growpart` fails before `resize2fs`, the partition table can be restored from the GPT backup:

```bash
# EMERGENCY ONLY: Restore GPT from backup
sudo sgdisk -l /tmp/gpt-backup-*.bin /dev/sda
sudo reboot
```

**Agent instruction: If Step 2 has been executed (partitions deleted), there is no undo. Proceed with Steps 3-5. If Step 2 has NOT been executed yet, the operation can be safely cancelled.**

---

## Operation 2: System Update (Kernel + Security)

This operation is documented in detail in **`How-to-Update.md`** in this repository. The agent MUST read that file before executing any updates.

### TL;DR — Critical Rules for Updates

1. **ALWAYS read `How-to-Update.md` first** — do not execute from memory
2. **NEVER reboot without configuring GRUB fallback** (Phase 5 in How-to-Update.md)
3. **NEVER assume DKMS auto-built the WiFi driver** — always verify with `dkms status`
4. **NEVER set new kernel as GRUB default until WiFi is confirmed working**
5. **If DKMS build fails for new kernel → ABORT and ROLLBACK immediately**

### Non-Kernel Updates (Safe Path)

For security updates that do NOT touch the kernel:

```bash
# Uncomment sources
sudo sed -i 's/^#deb/deb/' /etc/apt/sources.list
for list in /etc/apt/sources.list.d/*.list; do
  [ -f "$list" ] && sudo sed -i 's/^#deb/deb/' "$list"
done

sudo apt-get update
sudo apt-get upgrade -y --exclude=linux-image-*,linux-headers-*,linux-modules-*

# Comment sources back
sudo sed -i '/^deb/ s/^/#/' /etc/apt/sources.list
for list in /etc/apt/sources.list.d/*.list; do
  [ -f "$list" ] && sudo sed -i '/^deb/ s/^/#/' "$list"
done
```

### Full System Update (Kernel Included)

**Execute How-to-Update.md Phases 1-7 in order. Do NOT skip phases.**

The summary of phases:

| Phase | Action | Can Rollback? |
|-------|--------|----------------|
| 1 | Uncomment apt sources | Yes |
| 2 | Remove holds and pinning | Yes |
| 3 | `apt-get update && dist-upgrade` | Partial — kernel installed but not booted |
| 4 | Verify DKMS built wl.ko for new kernel | Yes — if DKMS fails, don't reboot |
| 5 | Configure GRUB fallback (old kernel = default) | Yes |
| 6 | `grub-reboot` into new kernel (one-time) | No after reboot — but power cycle reverts |
| 7 | Re-lock system (holds, preferences, sources) | N/A — final state |

---

## Agent Prompt Template

When delegating post-install operations, use one of these prompts:

### For macOS Erasure (Operation 1):

```
You are performing a post-install operation on a headless Mac Pro 2013 running Ubuntu 24.04
via SSH. This machine has ZERO physical access and WiFi-only networking via a proprietary
Broadcom BCM4360 wl driver compiled via DKMS with compatibility patches.

READ /Users/djtchill/Desktop/Mac/Post-Install.md COMPLETELY before executing anything.

You are executing OPERATION 1: Erase macOS and Expand Ubuntu to Full Disk.

KEY RULES:
- Execute Steps 1-5 in order. Do NOT skip any step.
- In Step 1, you MUST read the partition table and classify EVERY partition as macOS
  or Ubuntu BEFORE deleting anything. Output your classification for the user to confirm.
- In Step 2, DELETE ONE PARTITION AT A TIME. Re-read the partition table after each
  deletion because partition numbers may shift.
- In Step 3, verify free space is ADJACENT to the root partition before running growpart.
  If free space is not adjacent, STOP and ask the user — do NOT attempt to rearrange.
- NEVER delete partitions mounted at /, /boot, or /boot/efi.
- NEVER delete the EFI System Partition (ESP) — it's shared.
- Before Step 5 (reboot), verify WiFi works (ping test) AND all filesystems are mounted.
- After reboot, re-verify SSH, WiFi, and disk space before declaring success.

STOP AND ASK THE USER BEFORE:
- Deleting any partition you cannot classify
- Proceeding if growpart reports free space is not adjacent
- Any step that fails or produces unexpected output
```

### For System Update (Operation 2):

```
You are performing a post-install operation on a headless Mac Pro 2013 running Ubuntu 24.04
via SSH. This machine has ZERO physical access and WiFi-only networking via a proprietary
Broadcom BCM4360 wl driver compiled via DKMS with compatibility patches.

READ BOTH FILES COMPLETELY before executing anything:
1. /Users/djtchill/Desktop/Mac/Post-Install.md (this operation guide)
2. /Users/djtchill/Desktop/Mac/How-to-Update.md (detailed update process)

You are executing OPERATION 2: System Update.

KEY RULES:
- Read How-to-Update.md and execute Phases 1-7 IN ORDER. Do NOT skip any phase.
- Before each phase, state which phase you are executing.
- In Phase 4, if dkms build or install fails, STOP and enter ABORT AND ROLLBACK immediately.
  Do NOT attempt to proceed — the machine would be bricked without WiFi.
- In Phase 5, verify `grub-editenv list` shows the old kernel as saved default
  BEFORE rebooting.
- In Phase 6, use `grub-reboot` (NOT `grub-set-default`) to boot the new kernel one time.
- After reboot, verify WiFi works (ping test) BEFORE proceeding to Phase 7.
- If SSH does not reconnect within 120 seconds of reboot, the new kernel is broken.
  Inform the user: "Power-cycle the Mac Pro — it will boot the old kernel (GRUB saved default)."

DO NOT:
- Run apt-get dist-upgrade without unlocking sources and removing holds first
- Reboot without GRUB fallback configured
- Set the new kernel as GRUB default until it is verified working with WiFi
- Remove the old kernel until the new one has been stable for days
- Suppress or ignore DKMS build failures
- Use --force flags with dkms to bypass build failures
```

### For Both Operations Combined:

```
You are performing post-install operations on a headless Mac Pro 2013 running Ubuntu 24.04
via SSH. This machine has ZERO physical access and WiFi-only networking via a proprietary
Broadcom BCM4360 wl driver compiled via DKMS with compatibility patches.

READ ALL THREE FILES COMPLETELY before executing anything:
1. /Users/djtchill/Desktop/Mac/Post-Install.md (operation guide)
2. /Users/djtchill/Desktop/Mac/How-to-Update.md (update process)
3. /Users/djtchill/Desktop/Mac/AGENTS.md (project constraints)

You are executing OPERATION 1 (Erase macOS/Expand) then OPERATION 2 (System Update).
The macOS erasure MUST happen FIRST — expanding the root partition provides more space
and eliminates the dual-boot complexity. Then run the full system update.

EXECUTION ORDER:
1. Read all documentation files
2. Execute Operation 1 (Erase macOS) Steps 1-5 from Post-Install.md
3. Verify system health after reboot
4. Execute Operation 2 (System Update) Phases 1-7 from How-to-Update.md
5. Final verification after update reboot

CRITICAL: If Operation 1 fails at any step, DO NOT proceed to Operation 2.
Fix the issue or report to user. A broken partition layout + a kernel update
is the worst possible combination for a headless machine.

Between operations: verify SSH + WiFi + df before starting the next operation.
```

---

## Known Constraints (from AGENTS.md)

- **Zero physical access** — all operations remote via SSH
- **WiFi-only networking** — `wl` driver must work for SSH access
- **DKMS patches at `/usr/src/broadcom-sta-6.30.223.271/`** — driver won't compile on 6.8+ without them
- **Kernel pinned to `6.8.0-100-generic`** — apt preferences + holds + commented sources
- **Disk is `/dev/sda`** (Apple PCIe SSD via AHCI, NOT NVMe)
- **EFI System Partition at `/boot/efi`** — FAT32, shared between macOS and Ubuntu (in dual-boot)
- **Apple EFI 1.1 bug** — `efibootmgr` requires `LIBEFIVAR_OPS=efivarfs`
- **Shell commands via `sh -c` use dash** — POSIX-only syntax (no `[[ ]]`, no arrays, no `<<<`)
- **`bless --nextonly` only reverts if firmware can't find bootloader** — does NOT protect against kernel panic or broken WiFi