# Mac Pro 2013 Ubuntu Autoinstall - AGENTS.md

## Project Overview

Automated Ubuntu 24.04.4 LTS Server installer for headless Mac Pro 2013 (MacPro6,1) with Broadcom BCM4360 WiFi. Uses minimal ISO modification — only `autoinstall.yaml` and a `packages/` directory of required debs are injected into the stock Ubuntu ISO.

## Project Structure

```
/Users/djtchill/Desktop/Mac/
├── autoinstall.yaml                 # Autoinstall configuration (added to ISO at /)
├── build-iso.sh                     # ISO builder (xorriso)
├── packages/                        # .deb files for driver compilation (~36 debs, ~75MB)
│   ├── broadcom-sta-dkms_*.deb      # Broadcom WiFi driver source
│   ├── dkms_*.deb                   # Dynamic Kernel Module Support
│   ├── linux-headers-6.8.0-100*     # Kernel headers matching ISO kernel
│   ├── gcc-13_*, make_*, etc.       # Build toolchain
│   └── ...
├── README.md                        # Documentation
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

1. **Minimal ISO modification**: Only `autoinstall.yaml` and `packages/` directory are added via `xorriso -map`. EFI boot structure is preserved with `-boot_image any keep`. No initrd hacking, no kernel swapping, no driver pre-compilation.

2. **Compile during install**: The `early-commands` section installs kernel headers and build tools from `/cdrom/macpro-pkgs/`, then compiles `wl.ko` via DKMS against the running kernel. The `late-commands` section repeats this in a 4-stage `dpkg --root /target` install to ensure the driver persists in the target system.

3. **GPU**: AMD FirePro uses built-in `amdgpu` driver. Only `nomodeset amdgpu.si.modeset=0` kernel params needed (set in GRUB at boot time, not baked into ISO).

4. **Network matching**: Uses `wl0` interface ID with `match: driver: wl` in netplan to handle variable interface names. The late-commands generates a netplan config using the detected interface name with `printf` (not heredoc, to avoid YAML indentation issues).

5. **Storage**: Mac Pro 2013 uses Apple PCIe SSDs connected via AHCI (not NVMe), so the internal disk appears as `/dev/sda`.

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
- `build-iso.sh` - ISO build script using xorriso
- `prereqs/` - Stock Ubuntu ISO directory (only `*.iso` files, gitignored)
- `.gitignore` - Excludes `*.iso`, `*.qcow2`, `ssh-*/`, `.sisyphus/`, `.DS_Store`

## Key Constraints

- Kernel version is hardcoded to `6.8.0-100-generic` — must match the ISO's kernel
- DKMS cross-kernel build: `dkms build -k <version>` compiles against the specified kernel's headers, not the running kernel
- `dpkg --root /target` packages must be installed in dependency order (Stage 1: headers → Stage 2: libs → Stage 3: tools → Stage 4: dkms)
- Netplan interface keys must be actual names or logical IDs (not `wifi-iface`)