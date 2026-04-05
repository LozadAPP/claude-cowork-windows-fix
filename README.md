# 🔧 Claude Cowork Windows Fix

**Diagnostic tool and fix guide for Claude Desktop Cowork errors on Windows**

[![Platform](https://img.shields.io/badge/Platform-Windows%2010%2F11-0078D6?logo=windows&logoColor=white)](https://www.microsoft.com/windows)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Claude Desktop](https://img.shields.io/badge/Claude-Desktop-cc785c?logo=anthropic&logoColor=white)](https://claude.ai/download)

---

## The Problem

Claude Desktop's **Cowork** feature (background agents) fails to start on many Windows machines. Users see errors like:

- `"VM service not running. The service failed to start"`
- `"signature verification initialization failed"`
- `"EXDEV: cross-device link not permitted, rename 'C:\...' -> 'D:\...'"`
- `"Incorrect function" (ExitCode 1066)`
- Cowork progress bar stuck at ~80% then failing silently

There are **30+ open GitHub issues** with no official solution from Anthropic. A documentation request has been filed at [anthropics/claude-code#43756](https://github.com/anthropics/claude-code/issues/43756).

---

## Root Causes Found

After extensive debugging, two root causes were identified:

### 1. Signature Verification Failure

When Windows is **not updated** or **not activated**, the MSIX package permissions for `CoworkVMService` break. The service cannot resolve its own executable path, producing:

```
signature verification initialization failed
```

This happens because Windows' code signing infrastructure relies on up-to-date root certificates and a valid license state to properly verify MSIX package signatures.

### 2. EXDEV Cross-Device Link Error

When the Windows setting **"Where new content is saved"** (`Settings > System > Storage > Where new content is saved`) is set to a drive **other than C:\**, the MSIX package runtime creates symlinks pointing to that drive. Claude's internal `fs.rename()` call then fails because it cannot move files across different drive letters:

```
EXDEV: cross-device link not permitted, rename 'C:\Users\...\Temp\...' -> 'D:\Users\...\AppData\...'
```

**This is the most common cause** and the easiest to miss.

---

## Quick Start

### One-liner (PowerShell as Administrator)

```powershell
irm https://raw.githubusercontent.com/LozadAPP/claude-cowork-windows-fix/main/diagnose.ps1 | iex
```

### Version en Español

```powershell
irm https://raw.githubusercontent.com/LozadAPP/claude-cowork-windows-fix/main/diagnose-es.ps1 | iex
```

### Manual download

```powershell
git clone https://github.com/LozadAPP/claude-cowork-windows-fix.git
cd claude-cowork-windows-fix
.\diagnose.ps1        # English
.\diagnose-es.ps1     # Español
```

The script checks all known causes and tells you exactly what to fix.

---

## Step-by-Step Fix

If you prefer to fix manually, follow these steps in order:

### Step 1 — Update Windows

Open `Settings > Windows Update` and install **all** available updates, including optional and cumulative updates. Reboot when prompted.

### Step 2 — Activate Windows

Open `Settings > System > Activation` and ensure Windows is activated. An unactivated Windows install can interfere with MSIX package signature verification.

### Step 3 — Set App Storage Location to C:\ ⚠️ CRITICAL

> **This is the fix for 90% of cases.**

1. Open `Settings > System > Storage > Where new content is saved`
   (or search for *"Where new content is saved"* in the Start menu)
2. Set **"New apps will save to:"** back to **`C:\`**
3. If other categories (documents, music, etc.) are also on another drive, consider moving them back to C:\ temporarily

This prevents the cross-device link error that breaks Cowork's file operations.

### Step 4 — Enable Required Windows Features

Open PowerShell as Administrator and run:

```powershell
# Enable WSL
dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart

# Enable Virtual Machine Platform
dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart

# Enable Hyper-V (Pro/Enterprise/Education only)
dism.exe /online /enable-feature /featurename:Microsoft-Hyper-V-All /all /norestart

# Enable Hypervisor Platform
dism.exe /online /enable-feature /featurename:HypervisorPlatform /all /norestart

# Set WSL 2 as default
wsl --set-default-version 2
```

### Step 5 — Backup your config (BEFORE uninstalling)

If you have MCP servers or custom settings configured in Claude Desktop, **back them up first**. The uninstall will delete them.

```powershell
# Create backup folder on your Desktop
New-Item -Path "$env:USERPROFILE\Desktop\Claude_Backup" -ItemType Directory -Force

# Backup your MCP servers config and preferences
Copy-Item "$env:APPDATA\Claude\claude_desktop_config.json" "$env:USERPROFILE\Desktop\Claude_Backup\" -ErrorAction SilentlyContinue
Copy-Item "$env:APPDATA\Claude\config.json" "$env:USERPROFILE\Desktop\Claude_Backup\" -ErrorAction SilentlyContinue
```

> After reinstalling Claude Desktop, restore your config:
> ```powershell
> Copy-Item "$env:USERPROFILE\Desktop\Claude_Backup\claude_desktop_config.json" "$env:APPDATA\Claude\" -ErrorAction SilentlyContinue
> ```
> **Note:** If the config path changed after reinstall (MSIX packages may use a different location), check with:
> ```powershell
> Get-ChildItem "$env:LOCALAPPDATA\Packages\Claude_*" -Recurse -Filter "claude_desktop_config.json"
> ```

### Step 6 — Clean Uninstall Claude Desktop (after backup)

```powershell
# Remove Claude Desktop (MSIX package)
Get-AppxPackage *Claude* | Remove-AppxPackage

# Delete leftover data
Remove-Item -Recurse -Force "$env:APPDATA\Claude" -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "$env:LOCALAPPDATA\Claude" -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "C:\ProgramData\Claude" -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "$env:LOCALAPPDATA\Packages\Claude_pzs8sxrjxfjjc" -ErrorAction SilentlyContinue
# If you had apps saving to D:\, also clean:
Remove-Item -Recurse -Force "D:\WpSystem\*\AppData\Local\Packages\Claude_pzs8sxrjxfjjc" -ErrorAction SilentlyContinue
```

### Step 7 — Reboot and Reinstall

1. **Restart** your computer (required for Windows features to take effect)
2. Download Claude Desktop from [claude.ai/download](https://claude.ai/download)
3. Install and launch
4. Try Cowork again — it should work

---

## How to Verify

After the fix, check the Cowork VM service log:

```powershell
Get-Content "C:\ProgramData\Claude\Logs\cowork-service.log" -Tail 20
```

**Expected output** (healthy):

```
[Server] Signature verification initialized
[Server] Client signature verified
Service ready. Listening on \\.\pipe\cowork-vm-service
[VM] VM started successfully
```

If you see `signature verification initialization failed` or `EXDEV` errors, revisit Steps 2-3.

---

## Quick Reference Table

| Error | Root Cause | Fix |
|-------|-----------|-----|
| `signature verification initialization failed` | Windows not updated or not activated | Update + activate Windows (Steps 1-2) |
| `EXDEV: cross-device link not permitted` | App storage set to non-C: drive | Change "Where new content is saved" to C:\ (Step 3) |
| `Incorrect function (ExitCode 1066)` | Missing virtualization features | Enable WSL2, Hyper-V, HypervisorPlatform (Step 4) |
| Stuck at ~80% / silent failure | Combination of the above | Follow all 6 steps |

---

## Related GitHub Issues

This fix addresses the following open issues in `anthropics/claude-code`:

[#37312](https://github.com/anthropics/claude-code/issues/37312) · [#29941](https://github.com/anthropics/claude-code/issues/29941) · [#32481](https://github.com/anthropics/claude-code/issues/32481) · [#27897](https://github.com/anthropics/claude-code/issues/27897) · [#38396](https://github.com/anthropics/claude-code/issues/38396) · [#32186](https://github.com/anthropics/claude-code/issues/32186) · [#30584](https://github.com/anthropics/claude-code/issues/30584) · [#36642](https://github.com/anthropics/claude-code/issues/36642) · [#25476](https://github.com/anthropics/claude-code/issues/25476) · [#36522](https://github.com/anthropics/claude-code/issues/36522) · [#40254](https://github.com/anthropics/claude-code/issues/40254) · [#38241](https://github.com/anthropics/claude-code/issues/38241)

> [#32481](https://github.com/anthropics/claude-code/issues/32481) was **closed as resolved** using this fix.

---

## Confirmed Working By

| User | Environment | Reference |
|------|-------------|-----------|
| [@AmerSarhan](https://github.com/AmerSarhan) | Windows 11 Pro 25H2 Build 26200 | [#32481](https://github.com/anthropics/claude-code/issues/32481) |
| [@JuergenEwen](https://github.com/JuergenEwen) | Confirmed root cause analysis | [#27897](https://github.com/anthropics/claude-code/issues/27897) |

---

## FAQ

**Q: Do I need to open Claude Desktop before running the diagnostic?**
No. The diagnostic reads existing logs and system configuration. You don't need Claude Desktop running.

**Q: Why does the EXDEV error happen if both paths look like C:\?**
Because Windows MSIX creates hidden symlinks inside `AppData\Local\Packages\Claude_pzs8sxrjxfjjc\` that redirect to another drive (like `D:\WpSystem\...`). The paths *look* like C:\ but internally go through D:\. You can verify this with the diagnostic script.

**Q: Will this fix break my other apps that are installed on D:\?**
No. You only need to change the storage setting, uninstall Claude, clean up, and reinstall. Other apps already installed on D:\ will continue working. You can change the setting back to D:\ after Claude is installed if you want — but Claude specifically needs to be on C:\.

**Q: I don't have a D:\ drive. Can I still have this problem?**
Yes. Any secondary drive (E:\, F:\, etc.) can cause the same issue if "New apps will save to" is set to it.

**Q: Does Windows activation really matter?**
In our testing, updating Windows + activating resolved the signature verification error. We can't say with 100% certainty which one was the key fix, but both together resolved it.

---

## Credits

- Created by **Cesar Lozada** ([@LozadAPP](https://github.com/LozadAPP))
- Debugging assisted by **Claude Code** (Anthropic)
- Thanks to the community members who tested and confirmed the fix

---

## License

[MIT](LICENSE) — Use it, share it, fix Windows with it.
