# Claude Desktop (Cowork) — Intune Deployment Package

## Package Contents

| File | Purpose |
|---|---|
| `Install.ps1` | Main install script — run by Intune during deployment |
| `Uninstall.ps1` | Uninstall script — run by Intune on app removal |
| `Detection.ps1` | Detection script — used by Intune to verify install state |
| `Claude.msix` | Claude Desktop MSIX installer *(you supply this — see Download below)* |

---

## Download the MSIX

Obtain the official Anthropic-signed MSIX directly from these stable redirect URLs.
Do **not** extract an MSIX from `ClaudeSetup.exe` — use these links.

| Architecture | URL |
|---|---|
| x64 | https://claude.ai/api/desktop/win32/x64/msix/latest/redirect |
| arm64 | https://claude.ai/api/desktop/win32/arm64/msix/latest/redirect |

Download the appropriate file and rename it to `Claude.msix` before packaging.

---

## Intune Win32 App Configuration

### 1. Package the App (IntuneWin)
Place all files in a single folder and run the Win32 Content Prep Tool:
```
IntuneWinAppUtil.exe -c .\ClaudeCowork\ -s Install.ps1 -o .\output\
```

### 2. App Information
| Field | Value |
|---|---|
| Name | Claude Desktop (Cowork) |
| Publisher | Anthropic |
| Install behavior | **System** |

### 3. Program Settings
| Field | Value |
|---|---|
| Install command | `powershell.exe -ExecutionPolicy Bypass -NonInteractive -File Install.ps1` |
| Uninstall command | `powershell.exe -ExecutionPolicy Bypass -NonInteractive -File Uninstall.ps1` |
| Install behavior | **System** |
| Device restart behavior | **Intune will force a restart** (script returns 3010) |
| Return codes | 0 = Success, 1 = Failed, 3010 = Success reboot required |

### 4. Detection Rules
| Field | Value |
|---|---|
| Rules format | **Use a custom detection script** |
| Script file | `Detection.ps1` |
| Run script as 32-bit | No |
| Enforce script signature check | No (or Yes if your org requires signed scripts) |
| Run this script using the logged-on credentials | **Yes** (user context required for Get-AppxPackage) |

---

## What Changed From Previous Version

### Install.ps1
- **Removed** `AllowAllTrustedApps` registry key — not required when using the official
  Anthropic-signed MSIX. Setting this was a security concern and is no longer needed.
- **Removed** `Add-AppxPackage` per-user fallback — this cannot succeed from SYSTEM
  context and was causing the `0x80073CF9` error. The provisioned install path is the
  correct and only supported method for Intune SYSTEM context deployments.
- **Added** `-Regions "all"` to `Add-AppxProvisionedPackage` — this is Anthropic's
  current recommended flag per their enterprise deployment documentation.
- **Simplified** — the cert import workaround is not needed with the official MSIX.

### Detection.ps1
- **Removed** `AllowAllTrustedApps` registry check — this key is no longer set by the
  installer, so checking for it was causing false negatives on re-detection.

### Uninstall.ps1
- No functional changes.

---

## Known Issues & Notes

### VirtualMachinePlatform Reboot
Enabling VirtualMachinePlatform always requires a reboot. The script returns exit code 3010
to signal Intune to schedule one. Cowork will not function correctly until the reboot completes.

### Provisioned Package — Per-User Registration at Logon
`Add-AppxProvisionedPackage` stages the package machine-wide. It registers for each user
the first time they log on after the provisioned install. This means:
- The Detection script (running in user context) will return **Not detected** until the
  user has logged on at least once after install.
- If users report Claude not appearing after deployment, having them log off and back on
  resolves it.

### AppLocker Environments
If your org uses AppLocker, add a publisher rule for `CN="Anthropic, PBC"` before
deployment. Without it, machines will refuse to launch the app even after a successful
install, and the error will not clearly explain why.

### Squirrel Legacy Cleanup
If any users have the old `.exe`-based Claude Desktop installed, `Install.ps1` will
attempt to remove it before installing the MSIX. Conflicts between Squirrel and MSIX
installs are a known source of broken deployments.

### Auto-Updates
By default, Claude Desktop will auto-update, which can cause version drift across your
fleet. To disable auto-updates and manage versioning through Intune, set the following
registry key via an Intune configuration profile or GPO:

```
HKLM:\SOFTWARE\Policies\Claude
DisableAutoUpdates = 1 (DWORD)
```

See [Anthropic enterprise configuration docs](https://support.claude.com/en/articles/12622667-enterprise-configuration-for-claude-desktop) for the full list of managed policy keys.

### Log Locations
| Log | Path |
|---|---|
| Install | `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\ClaudeCowork_Install.log` |
| Uninstall | `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\ClaudeCowork_Uninstall.log` |
| Detection | `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\ClaudeCowork_Detection.log` |
| Intune agent | `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log` |

---

## Pre-Deployment Checklist

- [ ] Download `Claude.msix` from the official Anthropic redirect URL (see Download section above)
- [ ] Confirm machines are on Windows 10 1903+ or Windows 11
- [ ] Confirm users have a paid Claude plan (Pro, Max, Team, or Enterprise)
- [ ] Verify VirtualMachinePlatform is not blocked by Group Policy
- [ ] If using AppLocker, add publisher rule for `CN="Anthropic, PBC"` before deployment
- [ ] Consider setting `DisableAutoUpdates = 1` via policy before rollout
- [ ] Test on a single pilot machine before broad rollout
- [ ] Confirm Intune detection script is set to run in **user context**
- [ ] Plan for the mandatory reboot (VirtualMachinePlatform requirement)
