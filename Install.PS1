<#
.SYNOPSIS
    Installs Claude Desktop (Cowork) MSIX and configures required Windows features for Intune deployment.
.DESCRIPTION
    Handles full lifecycle for Intune Win32 deployment:
      - Removes legacy Squirrel-based Claude install if present
      - Enables VirtualMachinePlatform (required for Cowork)
      - Installs Claude MSIX via provisioning (all users) using Anthropic's recommended method
      - Attempts to register the package for the currently logged-on user immediately,
        so Intune detection passes without requiring a logoff/logon cycle
    Returns:
        0    - Success, package registered for current user (or no user logged on and no reboot needed)
        3010 - Success, reboot required (VirtualMachinePlatform was just enabled, or no user
               was logged on so per-user registration will happen at next logon)
        1    - Failure
.NOTES
    Deploy as: Win32 app, run in SYSTEM context
    Requirement: Windows 10 1903+ or Windows 11
    MSIX source: https://claude.ai/api/desktop/win32/x64/msix/latest/redirect (x64)
                 https://claude.ai/api/desktop/win32/arm64/msix/latest/redirect (arm64)
#>

# =============================
# VARIABLES
# =============================
$AppName        = "Claude Desktop (Cowork)"
$MsixFileName   = "Claude.msix"
$FeatureName    = "VirtualMachinePlatform"
$RebootRequired = $false

$LogRoot = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs"
$LogFile = Join-Path $LogRoot "ClaudeCowork_Install.log"

New-Item -ItemType Directory -Path $LogRoot -Force | Out-Null
Start-Transcript -Path $LogFile -Append -Force

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
$MsixPath   = Join-Path $ScriptRoot $MsixFileName

# =============================
# HELPER FUNCTIONS
# =============================
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] [$Level] $Message"
}

function Get-LoggedOnUser {
    # Uses `query user` which reliably returns the active interactive session
    # even when the script runs in a non-interactive SYSTEM context.
    # Win32_ComputerSystem.UserName is NOT used -- it returns empty from SYSTEM
    # sessions even when a user is sitting at the machine.
    try {
        $queryOutput = & "$env:SystemRoot\System32\query.exe" user 2>$null
        if ($queryOutput) {
            foreach ($line in $queryOutput) {
                if ($line -match "USERNAME") { continue }
                if ($line -match "Active") {
                    $username = ($line.Trim() -split "\s+")[0] -replace "^>", ""
                    if ($username) {
                        Write-Log "Detected active session for user: $username"
                        return $username
                    }
                }
            }
        }
    } catch {
        Write-Log "query user failed: $_" "WARN"
    }
    return $null
}

# =============================
# ERROR HANDLING
# =============================
$ErrorActionPreference = "Stop"

try {

    # =============================
    # PRE-FLIGHT CHECKS
    # =============================
    Write-Log "Starting $AppName installation"
    Write-Log "Script root: $ScriptRoot"
    Write-Log "MSIX path: $MsixPath"

    if (-not (Test-Path $MsixPath)) {
        Write-Log "MSIX package not found at: $MsixPath" "ERROR"
        Stop-Transcript
        exit 1
    }

    $msixSize = (Get-Item $MsixPath).Length
    Write-Log "MSIX found, size: $([math]::Round($msixSize / 1MB, 2)) MB"

    if ($msixSize -lt 1MB) {
        Write-Log "MSIX appears too small - possible corrupt download" "ERROR"
        Stop-Transcript
        exit 1
    }

    # =============================
    # REMOVE LEGACY SQUIRREL INSTALL
    # Squirrel-based Claude conflicts with MSIX install
    # =============================
    Write-Log "Checking for legacy Squirrel-based Claude install..."

    $squirrelPaths = @(
        "$env:LOCALAPPDATA\AnthropicClaude",
        "C:\Users\*\AppData\Local\AnthropicClaude"
    )

    foreach ($path in $squirrelPaths) {
        $resolved = Get-Item -Path $path -ErrorAction SilentlyContinue
        foreach ($dir in $resolved) {
            $squirrelExe = Join-Path $dir.FullName "Update.exe"
            if (Test-Path $squirrelExe) {
                Write-Log "Found legacy install at $($dir.FullName), removing..."
                try {
                    Start-Process -FilePath $squirrelExe -ArgumentList "--uninstall" -Wait -ErrorAction SilentlyContinue
                } catch {
                    Write-Log "Squirrel uninstall failed, forcing removal: $_" "WARN"
                }
                Remove-Item -Path $dir.FullName -Recurse -Force -ErrorAction SilentlyContinue
                Write-Log "Legacy install removed"
            }
        }
    }

    # Kill any running Claude processes
    Write-Log "Stopping any running Claude processes..."
    Get-Process -Name "Claude" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    # =============================
    # ENABLE VIRTUALMACHINEPLATFORM
    # Required for Cowork functionality
    # =============================
    Write-Log "Checking $FeatureName feature state..."

    $feature = Get-WindowsOptionalFeature -Online -FeatureName $FeatureName -ErrorAction SilentlyContinue

    if ($null -eq $feature) {
        Write-Log "$FeatureName feature not found on this OS - Cowork may not function" "WARN"
    } elseif ($feature.State -eq "Enabled") {
        Write-Log "$FeatureName already enabled"
    } else {
        Write-Log "Enabling $FeatureName..."
        $result = Enable-WindowsOptionalFeature -Online -FeatureName $FeatureName -All -NoRestart
        if ($result.RestartNeeded) {
            Write-Log "$FeatureName enabled - reboot will be required"
            $RebootRequired = $true
        } else {
            Write-Log "$FeatureName enabled - no reboot needed"
        }
    }

    # =============================
    # INSTALL CLAUDE MSIX
    # Provisioned (all-users) install using Anthropic's recommended method.
    # -Regions "all" ensures the package is staged for all regions/languages.
    # Note: Add-AppxPackage per-user fallback is intentionally omitted --
    # it cannot succeed from SYSTEM context and is not the supported path.
    # =============================
    Write-Log "Installing Claude MSIX (provisioned, all users)..."

    try {
        Add-AppxProvisionedPackage -Online -PackagePath $MsixPath -SkipLicense -Regions "all" -ErrorAction Stop
        Write-Log "Provisioned install succeeded"
        # Provisioned packages register per-user at next logon; reboot ensures clean state
        $RebootRequired = $true
    } catch {
        Write-Log "Provisioned install failed: $_" "ERROR"
        Stop-Transcript
        exit 1
    }

    # =============================
    # VERIFY INSTALL
    # =============================
    Write-Log "Verifying installation (provisioned package)..."

    $provPackage = Get-AppxProvisionedPackage -Online | Where-Object {
        $_.DisplayName -like "*Claude*" -or $_.DisplayName -like "*Anthropic*"
    }

    if ($provPackage) {
        Write-Log "Verification passed: $($provPackage.DisplayName) -- provisioned successfully"
    } else {
        # Non-fatal: DISM staging can occasionally take a moment to reflect
        Write-Log "Verification warning: Provisioned package not immediately visible via DISM -- may still be staged" "WARN"
    }

    # =============================
    # REGISTER FOR LOGGED-ON USER
    # Provisioned packages normally register at next logon, which causes Intune
    # detection to show "Failed" until the user logs off and back on -- alarming
    # users and generating unnecessary service desk calls.
    # We attempt registration now so detection passes immediately.
    # This is non-fatal: if it fails, the reboot/logon cycle handles it.
    # =============================
    $loggedOnUser = Get-LoggedOnUser

    if ($loggedOnUser -and $provPackage) {
        Write-Log "Logged-on user detected: $loggedOnUser -- attempting immediate registration..."
        try {
            # After Add-AppxProvisionedPackage the package may not yet be fully extracted
            # to the WindowsApps path. Search multiple candidate locations in order:
            #   1. InstallLocation from provisioned package (WindowsApps -- available after reboot)
            #   2. PackageName-based path under WindowsApps
            #   3. Any matching Claude folder under WindowsApps (handles version variations)
            $manifestPath = $null

            $candidatePaths = @(
                (Join-Path $provPackage.InstallLocation "AppxManifest.xml"),
                (Join-Path "C:\Program Files\WindowsApps\$($provPackage.PackageName)" "AppxManifest.xml")
            )

            # Also search WindowsApps for any matching Claude package folder
            $windowsAppsMatch = Get-ChildItem "C:\Program Files\WindowsApps" -Filter "Claude_*" -Directory -ErrorAction SilentlyContinue |
                Where-Object { Test-Path (Join-Path $_.FullName "AppxManifest.xml") } |
                Select-Object -First 1

            if ($windowsAppsMatch) {
                $candidatePaths += (Join-Path $windowsAppsMatch.FullName "AppxManifest.xml")
            }

            foreach ($candidate in $candidatePaths) {
                if ($candidate -and (Test-Path $candidate)) {
                    $manifestPath = $candidate
                    Write-Log "Found AppxManifest.xml at: $manifestPath"
                    break
                }
            }

            if ($manifestPath) {
                Add-AppxPackage -Register -Path $manifestPath -DisableDevelopmentMode -ErrorAction Stop
                Write-Log "Package registered for $loggedOnUser -- detection will pass immediately"
                $RebootRequired = $false
            } else {
                Write-Log "AppxManifest.xml not found in any candidate path -- will register at next logon" "WARN"
            }
        } catch {
            Write-Log "Immediate registration failed (non-fatal -- will register at next logon): $_" "WARN"
        }
    } elseif (-not $loggedOnUser) {
        Write-Log "No interactive user logged on -- package will register at next logon"
        # Ensure we reboot so the logon that follows triggers per-user registration
        $RebootRequired = $true
    }

    # =============================
    # EXIT
    # =============================
    if ($RebootRequired) {
        Write-Log "$AppName installation completed successfully. Reboot required."
        Stop-Transcript
        exit 3010
    } else {
        Write-Log "$AppName installation completed successfully. No reboot required."
        Stop-Transcript
        exit 0
    }

} catch {
    Write-Log "Unhandled exception during installation: $_" "ERROR"
    Stop-Transcript
    exit 1
}
