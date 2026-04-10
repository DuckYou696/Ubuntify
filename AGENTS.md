# Mac Pro 2013 Ubuntu Autoinstall - AGENTS.md

## Project Overview

Headless Ubuntu 24.04.4 LTS Server deployment for Mac Pro 2013 (MacPro6,1) with Broadcom BCM4360 WiFi. The machine is only accessible via SSH — zero physical access (no keyboard, monitor, or mouse). Cannot disable macOS SIP to install custom bootloader. The deployment must repartition the internal disk remotely, extract the installer to an EFI System Partition, use `bless` to set boot device, and reboot into an automated autoinstall.

## Hardware Specifications

- **Model**: Mac Pro 2013 (MacPro6,1)
- **Current OS**: macOS 12.7.6 (Monterey)
- **Access**: SSH only — zero physical access
- **GPU**: AMD FirePro D300/D500/D700 (amdgpu, needs `nomodeset amdgpu.si.modeset=0`)
- **WiFi**: Broadcom BCM4360 (proprietary `wl` driver, NOT in Ubuntu)
- **Storage**: Apple PCIe SSD via AHCI → `/dev/sda` (not NVMe)
- **No Ethernet port** — WiFi is the only network path
- **Cannot disable SIP** — stuck with Apple's default bootloader
- **MacBook available on network** — can serve as monitoring endpoint and fallback

## Project Structure

```
/Users/djtchill/Desktop/Mac/
├── autoinstall.yaml                 # Autoinstall configuration (added to ISO at /)
├── build-iso.sh                     # ISO builder (xorriso) — injects config, cidata, GRUB, packages
├── prepare-headless-deploy.sh       # macOS-side script: repartition + extract + bless via SSH
├── packages/                        # .deb files for driver compilation (~36 debs, ~75MB)
│   ├── broadcom-sta-dkms_*.deb      # Broadcom WiFi driver source
│   ├── dkms_*.deb                   # Dynamic Kernel Module Support
│   ├── linux-headers-6.8.0-100*     # Kernel headers matching ISO kernel
│   ├── gcc-13_*, make_*, etc.       # Build toolchain
│   └── ...
├── README.md                        # Documentation
├── PLAN.md                          # Implementation plan for headless deployment
├── macpro-monitor/                  # Node.js webhook monitor
│   ├── server.js
│   ├── start.sh / stop.sh / reset.sh
│   └── logs/
└── prereqs/                         # Stock Ubuntu ISO (*.iso gitignored)
```

## Build/Lint/Test Commands

### Build ISO
```bash
sudo ./build-iso.sh
```

### Node.js Monitor
```bash
cd macpro-monitor && ./start.sh    # Start (port 8080)
./macpro-monitor/stop.sh           # Stop
```

## Core Design Decisions

1. **Minimal ISO modification**: `autoinstall.yaml`, `cidata/`, `packages/`, and a pre-baked GRUB config are added via `xorriso -map`. EFI boot structure is preserved with `-boot_image any keep`. No initrd hacking, no kernel swapping, no driver pre-compilation.

2. **Compile during install**: The `early-commands` section installs kernel headers and build tools from `/cdrom/macpro-pkgs/`, then compiles `wl.ko` via DKMS against the running kernel. The `late-commands` section repeats this in a 4-stage `dpkg --root /target` install to ensure the driver persists in the target system. Error logging via `/run/macpro.log` at each stage; warnings don't abort install.

3. **GPU**: AMD FirePro uses built-in `amdgpu` driver. Only `nomodeset amdgpu.si.modeset=0` kernel params needed — pre-baked in GRUB config, not entered manually.

4. **Network matching**: Uses `wl0` interface ID with `match: driver: wl` in netplan. The late-commands generates netplan config using the detected interface name with `printf` (not heredoc — indentation inside `|` blocks adds unwanted spaces).

5. **Storage**: Mac Pro 2013 uses Apple PCIe SSDs via AHCI (not NVMe), so internal disk is `/dev/sda`.

6. **Remote boot via `bless`**: For zero-physical-access deployment, use `bless --setBoot --mount <esp>` from macOS SSH to set the installer ESP as next boot device. GRUB parameters are pre-baked in `EFI/boot/grub.cfg` — no manual keyboard input needed.

7. **SSH into installer**: `early-commands` starts `sshd` after WiFi driver compilation for remote debugging during installation. The `ssh: install-server: true` config only applies to the target system.

8. **NoCloud datasource**: The ISO includes `/cidata/user-data`, `/cidata/meta-data`, and `/cidata/vendor-data` for `ds=nocloud` discovery. Kernel param `autoinstall` bypasses the confirmation prompt for zero-touch deployment.

9. **Autoinstall config discovery precedence**: kernel cmdline > root of install system > cloud-config (NoCloud) > root of install medium (ISO). Our `/autoinstall.yaml` at ISO root is found via method 4 regardless of `ds=nocloud`.

## Boot Methods

| Method | Physical Access? | Status |
|--------|-----------------|--------|
| USB + auto GRUB | Required (keyboard to hold Option) | Implemented (build-iso.sh) |
| Internal disk + `bless` via SSH | None required | Implemented (prepare-headless-deploy.sh) |
| NetBoot from MacBook | None required | Not feasible (requires macOS Server + BSDP) |
| Target Disk Mode | Brief physical | Fallback only |

## Code Style Guidelines

### Shell Scripts (Bash)
```bash
set -e
set -o pipefail
readonly CONST="value"
local var="value"
```
Use `RED`, `GREEN`, `NC` color constants. Log to file with `tee`.

### YAML (autoinstall.yaml)
- Use `|` block scalar for shell commands to avoid YAML parsing issues
- Quote all strings containing special characters
- Use `match: driver: wl` with a logical interface ID (e.g., `wl0:`), not hardcoded interface names
- Use `printf` for netplan YAML generation (not heredoc — indentation inside `|` blocks adds unwanted spaces)

### JavaScript (Node.js)
```javascript
const PORT = 8080;
const MAX_UPDATES = 100;
function escapeHtml(str) {
    if (!str) return '';
    return String(str).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}
```

## Error Handling

| Language | Guidelines |
|----------|------------|
| Bash | `set -e` at start; `|| true` only when failure acceptable |
| Node.js | Validate inputs; handle HTTP errors gracefully |

## Naming Conventions

| Language | Variable | Function | Class | Constant |
|----------|----------|----------|-------|----------|
| Bash | `snake_case` | `snake_case()` | N/A | `UPPER_SNAKE` |
| JavaScript | `camelCase` | `camelCase()` | `PascalCase` | `UPPER_SNAKE` |

**Files:** `snake_case.sh`, `snake_case.js`

## Important Files

- `autoinstall.yaml` - The core autoinstall configuration (added to ISO at /)
- `packages/` - .deb files for driver compilation (added to ISO at /macpro-pkgs/)
- `build-iso.sh` - ISO build script using xorriso (injects config, cidata, GRUB, packages)
- `prepare-headless-deploy.sh` - macOS-side script for zero-physical-access deployment via bless
- `prereqs/` - Stock Ubuntu ISO directory (only `*.iso` files, gitignored)
- `PLAN.md` - Implementation plan for headless deployment workflow
- `.gitignore` - Excludes `*.iso`, `*.qcow2`, `ssh-*/`, `.sisyphus/`, `.DS_Store`

## Key Constraints

- **Zero physical access** — all operations must be performed remotely via SSH
- **Cannot disable SIP** — cannot install custom bootloader; must use Apple's `bless` command
- **WiFi-only networking** — no Ethernet; must compile `wl` driver before any network access
- **Kernel version hardcoded** to `6.8.0-100-generic` — must match the ISO's kernel
- **DKMS cross-kernel build**: `dkms build -k <version>` compiles against the specified kernel's headers, not the running kernel
- **`dpkg --root /target`** packages must be installed in dependency order (Stage 1: headers → Stage 2: libs → Stage 3: tools → Stage 4: dkms)
- **Netplan interface keys** must be actual names or logical IDs (not `wifi-iface`)
- **No `dd` ISO to partition** — Mac EFI expects FAT32 ESP with `/EFI/BOOT/BOOTX64.EFI`, not ISO9660
- **GRUB parameters must be pre-baked** — no manual keyboard input available during boot
- **Risk of unrecoverable state** — if installer fails, no physical access to recover; mitigations: webhook monitoring, SSH into installer, VirtualBox testing first