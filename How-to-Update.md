# How to Safely Update the Mac Pro Ubuntu System

This document describes the process for running comprehensive system updates (including kernel updates) on the headless Mac Pro 2013 Ubuntu installation.

> **CRITICAL**: This machine has **zero physical access** and **WiFi-only networking** via a proprietary Broadcom BCM4360 `wl` driver. A kernel update that breaks the WiFi driver bricks the machine remotely. Follow this process **exactly** — every verification step exists for a reason.

## The Circular Dependency Problem

```
New kernel installed → DKMS must recompile wl driver for new kernel
     ↑                                        ↓
     └── if wl fails on new kernel boot → NO SSH (no Ethernet) → BRICKED
```

The `broadcom-sta-dkms` package uses DKMS to auto-compile the `wl` WiFi driver when a new kernel is installed. During installation, 6 compatibility patches were applied to `/usr/src/broadcom-sta-6.30.223.271/` to make the driver compile on kernel 6.8+. These patches persist on disk. DKMS will attempt to use them when building for any new kernel.

**If the patches don't apply to the new kernel** (ABI break, new kernel API changes), the build fails, `wl.ko` is not produced for that kernel, and rebooting into it means no WiFi, no SSH, no recovery.

## Current Safeguards Installed

The autoinstall config locked the system down to prevent accidental kernel updates:

| Layer | File/Command | Effect |
|-------|-------------|--------|
| apt preferences | `/etc/apt/preferences.d/99-pin-kernel` | Blocks all `linux-{image,headers,modules}-*` at priority -1; allows only `6.8.0-100*` at 1001 |
| apt-mark hold | `linux-image-6.8.0-100-generic` etc. | `apt-get upgrade` skips held packages |
| Sources commented out | `/etc/apt/sources.list` | `apt-get update` finds nothing |
| Auto-updates disabled | `apt-daily*` masked, `APT::Periodic::* = 0` | Nothing runs automatically |
| Snap held | `snap refresh --hold=forever` | Snap kernel snaps frozen |

**These must be temporarily removed for the update, then re-applied afterward.**

## Prerequisites

Before starting, ensure:

1. You have **active SSH access** to the Mac Pro right now
2. The MacBook (or another machine on the network) is available for monitoring
3. You have **read this entire document** before executing anything
4. You understand: **if the process fails at the reboot step, you MUST have a fallback plan** (see Recovery section)

## Pre-Update Checklist

Run these **before** starting any update steps:

```bash
# 1. Record current kernel
CURRENT_KERNEL="$(uname -r)"
echo "Current kernel: $CURRENT_KERNEL"

# 2. Verify WiFi is working RIGHT NOW
ping -c 3 google.com || { echo "ABORT: WiFi not working before update"; exit 1; }

# 3. Verify DKMS patches still exist on disk
ls /usr/src/broadcom-sta-6.30.223.271/
cat /usr/src/broadcom-sta-6.30.223.271/.patched 2>/dev/null || \
  ls /usr/src/broadcom-sta-6.30.223.271/ | head -5

# 4. Record current DKMS status
dkms status broadcom-sta

# 5. Verify the wl module is loaded
lsmod | grep wl
modinfo wl 2>/dev/null || modinfo /lib/modules/$CURRENT_KERNEL/updates/dkms/wl.ko

# 6. Save this output — you'll need it for comparison
```

**If any of these fail, DO NOT proceed.** Fix the current system first.

---

## Update Process

### Phase 1: Enable apt Sources

```bash
# Uncomment all apt sources
sudo sed -i 's/^#deb/deb/' /etc/apt/sources.list
for list in /etc/apt/sources.list.d/*.list; do
  [ -f "$list" ] && sudo sed -i 's/^#deb/deb/' "$list"
done

# Verify sources are active
grep -c '^deb' /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null
```

### Phase 2: Remove Holds and Pinning

```bash
# Get current kernel version (for removing holds)
KVER="$(uname -r)"

# Remove apt-mark holds on current kernel packages
sudo apt-mark unhold "linux-image-${KVER}" 2>/dev/null || true
sudo apt-mark unhold "linux-headers-${KVER}" 2>/dev/null || true
sudo apt-mark unhold "linux-modules-${KVER}" 2>/dev/null || true
sudo apt-mark unhold "linux-modules-extra-${KVER}" 2>/dev/null || true

# Remove apt preferences that block kernel updates
sudo rm /etc/apt/preferences.d/99-pin-kernel

# Re-enable auto-update timers (optional, for this session only)
sudo systemctl unmask apt-daily.service apt-daily.timer 2>/dev/null || true
sudo systemctl unmask apt-daily-upgrade.service apt-daily-upgrade.timer 2>/dev/null || true
```

### Phase 3: Update Package Lists and Run Upgrade

```bash
# Update package lists
sudo apt-get update

# Run full upgrade (this will install a new kernel if available)
# --with-new-pkgs ensures new kernel packages are pulled in
sudo apt-get dist-upgrade -y
```

> **NOTE**: `dist-upgrade` may install a new kernel. DKMS will **automatically attempt** to build `broadcom-sta` for the new kernel during the `linux-headers-*` postinst. **Watch for DKMS build output** in the apt output. If you see `dkms: build failed`, proceed to Phase 4 Step 2 (manual DKMS build).

### Phase 4: Verify DKMS Built Successfully for New Kernel

This is the **most critical step**. Do not skip any sub-step.

```bash
# Step 1: Identify what kernels are now installed
ls /boot/vmlinuz-*
echo "---"
dkms status broadcom-sta

# Step 2: If DKMS did NOT auto-build for the new kernel, do it manually
# Replace NEW_KVER with the newly installed kernel version (e.g., 6.8.0-200-generic)
NEW_KVER="<from ls output above, the NEWEST version>"

# Check if DKMS already built for the new kernel
if ! dkms status broadcom-sta/6.30.223.271 -k "$NEW_KVER" 2>/dev/null | grep -q installed; then
  echo "DKMS did not auto-build for $NEW_KVER — building manually..."

  # Try DKMS build for the new kernel
  if ! sudo dkms build broadcom-sta/6.30.223.271 -k "$NEW_KVER"; then
    echo "=== DKMS BUILD FAILED FOR NEW KERNEL ==="
    echo "The WiFi driver CANNOT compile for kernel $NEW_KVER."
    echo "DO NOT REBOOT into this kernel."
    echo "Proceed to the ABORT AND ROLLBACK section below."
    exit 1
  fi

  # Install the module into the new kernel's modules directory
  if ! sudo dkms install broadcom-sta/6.30.223.271 -k "$NEW_KVER"; then
    echo "=== DKMS INSTALL FAILED FOR NEW KERNEL ==="
    echo "DO NOT REBOOT into this kernel."
    echo "Proceed to the ABORT AND ROLLBACK section below."
    exit 1
  fi
fi

# Step 3: Verify wl.ko exists for the new kernel
if [ ! -f "/lib/modules/$NEW_KVER/updates/dkms/wl.ko" ] && \
   [ ! -f "/lib/modules/$NEW_KVER/extra/wl.ko" ]; then
  echo "=== FATAL: wl.ko NOT FOUND for kernel $NEW_KVER ==="
  echo "DO NOT REBOOT into this kernel."
  echo "Proceed to the ABORT AND ROLLBACK section below."
  exit 1
fi

echo "SUCCESS: wl.ko exists for new kernel $NEW_KVER"

# Step 4: Verify the module can be loaded (without actually loading it —
# we're still on the old kernel, so modprobe would load the old one.
# Instead, check that the module metadata is valid.)
modinfo "/lib/modules/$NEW_KVER/updates/dkms/wl.ko" 2>/dev/null || \
  modinfo "/lib/modules/$NEW_KVER/extra/wl.ko" 2>/dev/null || {
  echo "=== FATAL: wl.ko metadata invalid for $NEW_KVER ==="
  exit 1
}

# Step 5: Ensure initramfs includes the wl module for the new kernel
sudo update-initramfs -u -k "$NEW_KVER"
```

### Phase 5: Configure GRUB Fallback (SAFETY NET)

**This is the key safety mechanism.** We configure GRUB so the machine defaults to the OLD (known-working) kernel. The new kernel is available in the GRUB menu, but NOT the default. If the new kernel fails, a simple power cycle reverts to the old kernel.

```bash
# Record kernel versions
OLD_KVER="$(uname -r)"
NEW_KVER="<from Phase 4>"

# Make GRUB remember the last booted entry and default to saved
sudo sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub
echo 'GRUB_SAVEDEFAULT=true' | sudo tee -a /etc/default/grub

# Set the OLD (working) kernel as the default boot entry
# This ensures a power cycle returns to the working kernel
sudo grub-set-default "Ubuntu, with Linux ${OLD_KVER}"

# Update GRUB
sudo update-grub

# Verify the default is set correctly
sudo grub-editenv list 2>/dev/null || sudo grep -A1 'menuentry' /boot/grub/grub.cfg | head -20
```

### Phase 6: Reboot Into New Kernel

```bash
# Use grub-reboot to boot the NEW kernel ONE TIME ONLY
# If it fails, power cycling will return to the OLD kernel (the saved default)
# Replace the menu entry name with the exact string from /boot/grub/grub.cfg
sudo grub-reboot "Ubuntu, with Linux ${NEW_KVER}"
sudo reboot
```

**After reboot, from your MacBook/other machine:**

```bash
# Wait 60-90 seconds, then attempt SSH
ssh macpro-linux

# If SSH connects, verify:
uname -r                    # Should show NEW kernel
lsmod | grep wl             # WiFi driver loaded?
ping -c 3 google.com        # WiFi actually working?
dkms status broadcom-sta    # DKMS reports installed for new kernel?
```

### Phase 7: Post-Update — Re-lock the System

**Only do this after confirming the new kernel works with WiFi.**

```bash
NEW_KVER="$(uname -r)"

# Step 1: Set new kernel as GRUB default (it works, make it permanent)
sudo grub-set-default "Ubuntu, with Linux ${NEW_KVER}"

# Step 2: Re-apply apt-mark holds for the NEW kernel
sudo apt-mark hold "linux-image-${NEW_KVER}"
sudo apt-mark hold "linux-headers-${NEW_KVER}"
sudo apt-mark hold "linux-modules-${NEW_KVER}"
sudo apt-mark hold "linux-modules-extra-${NEW_KVER}" 2>/dev/null || true

# Step 3: Re-write apt preferences to pin to the NEW kernel
sudo tee /etc/apt/preferences.d/99-pin-kernel > /dev/null << 'PREFS'
Package: linux-image-*
Pin: release o=Ubuntu
Pin-Priority: -1

Package: linux-headers-*
Pin: release o=Ubuntu
Pin-Priority: -1

Package: linux-modules-*
Pin: release o=Ubuntu
Pin-Priority: -1

Package: linux-image-REPLACE_KVER*
Pin: release o=Ubuntu
Pin-Priority: 1001

Package: linux-headers-REPLACE_KVER*
Pin: release o=Ubuntu
Pin-Priority: 1001

Package: linux-modules-REPLACE_KVER*
Pin: release o=Ubuntu
Pin-Priority: 1001
PREFS

# Replace placeholder with actual kernel ABI version
# e.g., 6.8.0-200 from NEW_KVER=6.8.0-200-generic
NEW_ABI="$(echo "$NEW_KVER" | sed 's/-generic$//')"
sudo sed -i "s/REPLACE_KVER/${NEW_ABI}/g" /etc/apt/preferences.d/99-pin-kernel

# Step 4: Comment out apt sources again
sudo sed -i '/^deb/ s/^/#/' /etc/apt/sources.list
for list in /etc/apt/sources.list.d/*.list; do
  [ -f "$list" ] && sudo sed -i '/^deb/ s/^/#/' "$list"
done

# Step 5: Re-disable auto-update timers
sudo systemctl mask apt-daily.service 2>/dev/null || true
sudo systemctl mask apt-daily.timer 2>/dev/null || true
sudo systemctl mask apt-daily-upgrade.service 2>/dev/null || true
sudo systemctl mask apt-daily-upgrade.timer 2>/dev/null || true

# Step 6: Re-disable auto-upgrades config
sudo tee /etc/apt/apt.conf.d/20auto-upgrades > /dev/null << 'EOF'
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";
APT::Periodic::Download-Upgradeable-Packages "0";
EOF

# Step 7: Hold snap refreshes
sudo snap refresh --hold=forever 2>/dev/null || true

# Step 8: Verify the lockdown
echo "=== Verification ==="
echo "Kernel: $(uname -r)"
apt-mark showhold | grep linux
cat /etc/apt/preferences.d/99-pin-kernel
grep -c '^#deb' /etc/apt/sources.list
dkms status broadcom-sta
lsmod | grep wl
ping -c 3 google.com
```

### Phase 8: Clean Up Old Kernel (Optional)

**Only after confirming the new kernel is fully stable.** Keep the old kernel as a fallback for at least a few days.

```bash
# List installed kernels
dpkg -l | grep linux-image | grep '^ii'

# Remove the old kernel (replace with your old version)
OLD_KVER="<previous kernel version>"
sudo apt-get remove "linux-image-${OLD_KVER}" "linux-headers-${OLD_KVER}" "linux-modules-${OLD_KVER}" "linux-modules-extra-${OLD_KVER}" -y
sudo update-grub
```

---

## ABORT AND ROLLBACK

If DKMS failed to build for the new kernel in Phase 4, or if the new kernel booted but WiFi is broken:

### Scenario A: DKMS build failed (before reboot)

The new kernel is installed but you haven't rebooted. You're still on the working kernel.

```bash
# Re-apply all safeguards immediately
KVER="$(uname -r)"
sudo apt-mark hold "linux-image-${KVER}"
sudo apt-mark hold "linux-headers-${KVER}"
sudo apt-mark hold "linux-modules-${KVER}"
sudo apt-mark hold "linux-modules-extra-${KVER}" 2>/dev/null || true

# Re-create apt preferences
NEW_ABI="$(echo "$KVER" | sed 's/-generic$//')"
sudo tee /etc/apt/preferences.d/99-pin-kernel > /dev/null << PREFS
Package: linux-image-*
Pin: release o=Ubuntu
Pin-Priority: -1

Package: linux-headers-*
Pin: release o=Ubuntu
Pin-Priority: -1

Package: linux-modules-*
Pin: release o=Ubuntu
Pin-Priority: -1

Package: linux-image-${NEW_ABI}*
Pin: release o=Ubuntu
Pin-Priority: 1001

Package: linux-headers-${NEW_ABI}*
Pin: release o=Ubuntu
Pin-Priority: 1001

Package: linux-modules-${NEW_ABI}*
Pin: release o=Ubuntu
Pin-Priority: 1001
PREFS

# Comment out sources
sudo sed -i '/^deb/ s/^/#/' /etc/apt/sources.list
for list in /etc/apt/sources.list.d/*.list; do
  [ -f "$list" ] && sudo sed -i '/^deb/ s/^/#/' "$list"
done

# Optionally remove the broken new kernel
# sudo apt-get remove "linux-image-${NEW_KVER}" "linux-headers-${NEW_KVER}" -y
# sudo update-grub

echo "ROLLBACK COMPLETE — system remains on working kernel $KVER"
```

### Scenario B: New kernel booted but WiFi doesn't work

You rebooted and can't SSH in. **This is the worst case.**

1. **Power cycle the Mac Pro** (pull power or use IPMI if available — this machine has no IPMI, so physical power cycle may be required)
2. GRUB is configured with `GRUB_DEFAULT=saved` and `GRUB_SAVEDEFAULT=true` from Phase 5. However, since the new kernel was selected via `grub-reboot` (one-time override), the **saved default** is still the old kernel. A normal reboot (not `grub-reboot`) will boot the old kernel.
3. If a simple reboot doesn't work (GRUB saved the new kernel as default because it booted successfully), you'll need:
   - **SSH from macOS side**: If macOS is still on the disk and `bless` was set with `--nextonly`, the firmware may revert to macOS. From macOS, you can re-bless the Ubuntu ESP and use `grub-editenv` or modify GRUB config to default to the old kernel.
   - **Physical access as last resort**: Hold Option at boot → select macOS → fix GRUB from macOS.

**Mitigation**: Before rebooting in Phase 6, verify that `sudo grub-editenv list` shows the old kernel as the saved default. The `grub-reboot` command only overrides for ONE boot; the saved default remains unchanged.

---

## Update Frequency Recommendation

| Update Type | Frequency | Risk |
|-------------|-----------|------|
| Security updates (non-kernel) | Monthly or as needed for critical CVEs | Low — DKMS not involved |
| Kernel update | Only when required by security CVE | Medium-High — requires full process above |
| Full `dist-upgrade` | Quarterly at most | High — likely pulls new kernel |

For **non-kernel security updates only**, a simplified process works:

```bash
# Just update non-kernel packages
sudo sed -i 's/^#deb/deb/' /etc/apt/sources.list
for list in /etc/apt/sources.list.d/*.list; do
  [ -f "$list" ] && sudo sed -i 's/^#deb/deb/' "$list"
done
sudo apt-get update
sudo apt-get upgrade -y --exclude=linux-image-*,linux-headers-*,linux-modules-*
sudo sed -i '/^deb/ s/^/#/' /etc/apt/sources.list
for list in /etc/apt/sources.list.d/*.list; do
  [ -f "$list" ] && sudo sed -i '/^deb/ s/^/#/' "$list"
done
```

This avoids the kernel entirely while still getting security patches for all other packages.

---

## Agent Execution Instructions

**When an AI agent is asked to perform a system update on this machine, it MUST follow these rules:**

### MANDATORY Rules

1. **NEVER run `apt-get dist-upgrade` or install a new kernel without following this entire document.**
2. **NEVER reboot without first configuring GRUB fallback** (Phase 5).
3. **NEVER skip Phase 4 verification** — DKMS status MUST show `installed` for the new kernel before rebooting.
4. **NEVER remove the apt preferences, holds, or commented-out sources without immediately re-applying them after the update.**
5. **NEVER assume DKMS auto-build succeeded** — always verify explicitly with `dkms status`.
6. **ALWAYS confirm WiFi works post-reboot before re-locking the system** (Phase 7).
7. **ALWAYS use `grub-reboot` for the first boot into a new kernel** — never set it as the GRUB default until verified working.
8. **If DKMS build fails, ALWAYS enter ABORT AND ROLLBACK immediately** — never attempt to reboot into a kernel without a working `wl.ko`.

### Execution Prompt Template

When delegating a system update to an agent, use this prompt:

```
You are updating a headless Mac Pro 2013 running Ubuntu 24.04 via SSH. This machine has
ZERO physical access and WiFi-only networking via a proprietary Broadcom BCM4360 wl driver.
A kernel update that breaks the WiFi driver will brick the machine remotely.

Read How-to-Update.md and follow it EXACTLY.

KEY RULES:
- Execute Phase 1 through Phase 7 in order. Do NOT skip any phase.
- Before each phase, state which phase you are executing.
- In Phase 4, if dkms build or install fails, STOP and enter ABORT AND ROLLBACK immediately.
- In Phase 5, verify `grub-editenv list` shows the old kernel as saved default BEFORE rebooting.
- In Phase 6, use `grub-reboot` (NOT `grub-set-default`) to boot the new kernel one time.
- After reboot, verify WiFi works (ping test) BEFORE proceeding to Phase 7.
- If SSH does not reconnect within 120 seconds of reboot, the new kernel is broken.
  The user must power-cycle the machine — it will boot the old kernel (GRUB saved default).

DO NOT:
- Run `apt-get dist-upgrade` without unlocking sources and removing holds first
- Reboot without GRUB fallback configured
- Set the new kernel as GRUB default until it is verified working
- Remove the old kernel until the new one has been stable for days
- Suppress or ignore DKMS build failures
- Use `--force` flags with dkms to bypass build failures
```

### Failure Protocol

If the agent encounters ANY failure during Phases 1-4:

1. **STOP** — do not proceed to next phase
2. **ROLLBACK** — re-apply all safeguards (holds, preferences, comment sources)
3. **REPORT** — output the exact error, the current kernel, and DKMS status
4. **DO NOT REBOOT** — the machine is still on a working kernel; keep it that way

If SSH does not reconnect after Phase 6 reboot:

1. Wait up to 120 seconds (the machine may be slow to boot)
2. Retry SSH every 15 seconds
3. If still failing after 120 seconds, inform the user: "New kernel WiFi is broken. Power-cycle the Mac Pro — it will boot the old working kernel (GRUB saved default)."