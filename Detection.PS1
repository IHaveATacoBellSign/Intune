<#
.SYNOPSIS
    Intune detection script for Claude Desktop (Cowork) MSIX deployment.
.DESCRIPTION
    Checks for:
      - MSIX package registered for current user (user context)
        OR provisioned machine-wide (SYSTEM context fallback)
      - VirtualMachinePlatform feature enabled (required for Cowork)
    Returns:
        exit 0 + output = Detected
        exit 1          = Not detected
.NOTES
    Runs in USER context when possible (Intune detection setting).
    Falls back to provisioned package check when running as SYSTEM,
    since Get-AppxPackage returns nothing from SYSTEM context for
    per-user registered MSIX packages.
#>

function Write-DetectionLog {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logRoot = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs"
    $logFile = Join-Path $logRoot "ClaudeCowork_Detection.log"
    try {
        Add-Content -Path $logFile -Value "[$timestamp] [$Level] $Message" -ErrorAction SilentlyContinue
    } catch {}
}

$allChecksPass = $true
$failReasons = @()
$package = $null

# =============================
# CHECK 1: MSIX package
# Try Get-AppxPackage first (works in user context).
# If running as SYSTEM it returns nothing, so fall back to
# Get-AppxProvisionedPackage which works from any context.
# =============================
Write-DetectionLog "Checking for Claude MSIX package..."

$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$isSystem = $currentUser -match "SYSTEM"
Write-DetectionLog "Running as: $currentUser (IsSystem: $isSystem)"

# Try per-user package first
$package = Get-AppxPackage -Name "*Anthropic*" -ErrorAction SilentlyContinue
if (-not $package) {
    $package = Get-AppxPackage -Name "*Claude*" -ErrorAction SilentlyContinue
}

if ($package) {
    Write-DetectionLog "Package found (per-user): $($package.Name) v$($package.Version)"
} else {
    # Fallback: check provisioned package (visible from SYSTEM context)
    Write-DetectionLog "Per-user package not found, checking provisioned packages..."
    $provPackage = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like "*Claude*" -or $_.DisplayName -like "*Anthropic*" }

    if ($provPackage) {
        Write-DetectionLog "Package found (provisioned): $($provPackage.DisplayName) v$($provPackage.Version)"
        # Create a minimal object so the result block works consistently
        $package = [PSCustomObject]@{
            Name    = $provPackage.DisplayName
            Version = $provPackage.Version
        }
    } else {
        Write-DetectionLog "No Claude/Anthropic package found in either per-user or provisioned checks" "FAIL"
        $allChecksPass = $false
        $failReasons += "MSIX package not found (checked per-user and provisioned)"
    }
}

# =============================
# CHECK 2: VirtualMachinePlatform enabled
# Required for Cowork to function
# =============================
Write-DetectionLog "Checking VirtualMachinePlatform feature..."

$vmFeature = Get-WindowsOptionalFeature -Online -FeatureName "VirtualMachinePlatform" -ErrorAction SilentlyContinue
if ($vmFeature -and $vmFeature.State -eq "Enabled") {
    Write-DetectionLog "VirtualMachinePlatform is enabled"
} else {
    Write-DetectionLog "VirtualMachinePlatform is NOT enabled" "FAIL"
    $allChecksPass = $false
    $failReasons += "VirtualMachinePlatform feature not enabled"
}

# =============================
# RESULT
# =============================
if ($allChecksPass) {
    Write-DetectionLog "All checks passed - Claude Desktop (Cowork) detected"
    Write-Host "Detected: $($package.Name) v$($package.Version)"
    exit 0
} else {
    Write-DetectionLog "Detection failed: $($failReasons -join '; ')"
    exit 1
}
