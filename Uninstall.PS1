<#
.SYNOPSIS
    Uninstalls Claude Desktop (Cowork) MSIX from all users.
.DESCRIPTION
    Removes both provisioned (all-users) and per-user MSIX registrations.
    Returns:
        0 - Success
        1 - Failure
#>

# =============================
# VARIABLES
# =============================
$AppName = "Claude Desktop (Cowork)"
$LogRoot = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs"
$LogFile = Join-Path $LogRoot "ClaudeCowork_Uninstall.log"

New-Item -ItemType Directory -Path $LogRoot -Force | Out-Null
Start-Transcript -Path $LogFile -Append -Force

# =============================
# HELPER FUNCTIONS
# =============================
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] [$Level] $Message"
}

$ErrorActionPreference = "Stop"

try {
    Write-Log "Starting $AppName uninstall"

    # Kill any running Claude processes
    Write-Log "Stopping any running Claude processes..."
    Get-Process -Name "Claude" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    # =============================
    # REMOVE PROVISIONED PACKAGE (all users)
    # =============================
    Write-Log "Removing provisioned MSIX package..."
    $provPackages = Get-AppxProvisionedPackage -Online | Where-Object {
        $_.DisplayName -like "*Claude*" -or $_.DisplayName -like "*Anthropic*"
    }

    if ($provPackages) {
        foreach ($pkg in $provPackages) {
            Write-Log "Removing provisioned package: $($pkg.DisplayName)"
            Remove-AppxProvisionedPackage -Online -PackageName $pkg.PackageName -ErrorAction SilentlyContinue
        }
    } else {
        Write-Log "No provisioned Claude package found"
    }

    # =============================
    # REMOVE PER-USER REGISTRATIONS
    # =============================
    Write-Log "Removing per-user MSIX registrations..."
    $appxPackages = Get-AppxPackage -Name "*Anthropic*" -AllUsers -ErrorAction SilentlyContinue
    if (-not $appxPackages) {
        $appxPackages = Get-AppxPackage -Name "*Claude*" -AllUsers -ErrorAction SilentlyContinue
    }

    if ($appxPackages) {
        foreach ($pkg in $appxPackages) {
            Write-Log "Removing package: $($pkg.Name) for all users"
            Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction SilentlyContinue
        }
    } else {
        Write-Log "No per-user Claude packages found"
    }

    # =============================
    # CLEAN UP LEFTOVER FOLDERS
    # =============================
    Write-Log "Cleaning up leftover folders..."
    $foldersToRemove = @(
        "C:\Users\*\AppData\Local\Claude-3p",
        "C:\Users\*\AppData\Local\Claude Nest-3p",
        "C:\Users\*\AppData\Local\AnthropicClaude",
        "C:\Users\*\AppData\Roaming\Claude"
    )

    foreach ($pattern in $foldersToRemove) {
        $resolved = Get-Item -Path $pattern -ErrorAction SilentlyContinue
        foreach ($folder in $resolved) {
            Write-Log "Removing: $($folder.FullName)"
            Remove-Item -Path $folder.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # =============================
    # CLEAN UP COWORK SERVICE
    # =============================
    Write-Log "Checking for CoworkVMService..."
    $coworkSvc = Get-Service -Name "*Cowork*" -ErrorAction SilentlyContinue
    if ($coworkSvc) {
        Write-Log "Stopping and removing CoworkVMService..."
        Stop-Service -Name $coworkSvc.Name -Force -ErrorAction SilentlyContinue
        sc.exe delete $coworkSvc.Name | Out-Null
        Write-Log "CoworkVMService removed"
    }

    Write-Log "$AppName uninstall completed successfully"
    Stop-Transcript
    exit 0

} catch {
    Write-Log "Uninstall failed: $_" "ERROR"
    Stop-Transcript
    exit 1
}
