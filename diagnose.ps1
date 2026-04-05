# =============================================================================
# Claude Cowork Windows Diagnostic Tool
# Version: 1.0.0
# Author: @LozadAPP
# Purpose: Diagnose common issues with Claude Desktop Cowork on Windows
# WARNING: This script is READ-ONLY. It does NOT modify anything on your system.
# =============================================================================

#Requires -Version 5.1

# --- Configuration ---
$ScriptVersion = "1.0.0"
$MinBuild = 26200
$MinUBR = 8117

# --- Helper Functions ---

function Write-Banner {
    Write-Host ""
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host "  |                                                          |" -ForegroundColor Cyan
    Write-Host "  |    Claude Cowork Windows Diagnostic Tool                 |" -ForegroundColor Cyan
    Write-Host "  |    Version $ScriptVersion                                       |" -ForegroundColor Cyan
    Write-Host "  |    Author: @LozadAPP                                    |" -ForegroundColor Cyan
    Write-Host "  |                                                          |" -ForegroundColor Cyan
    Write-Host "  |    This script is DIAGNOSIS ONLY - nothing is modified   |" -ForegroundColor Cyan
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host ""
}

function Write-SectionHeader {
    param([string]$Number, [string]$Title)
    Write-Host ""
    Write-Host "  [$Number] $Title" -ForegroundColor White
    Write-Host "  $('-' * ($Title.Length + $Number.Length + 4))" -ForegroundColor DarkGray
}

function Write-OK {
    param([string]$Message)
    Write-Host "      [OK] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "      [!!] $Message" -ForegroundColor Yellow
}

function Write-Err {
    param([string]$Message)
    Write-Host "      [XX] $Message" -ForegroundColor Red
}

function Write-Info {
    param([string]$Message)
    Write-Host "      [--] $Message" -ForegroundColor Gray
}

# --- Summary tracking ---
$summary = [ordered]@{}
$actions = @()

# Check if running as admin
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

Write-Banner

if (-not $isAdmin) {
    Write-Host "  NOTE: Running without Administrator privileges." -ForegroundColor Yellow
    Write-Host "  Some checks (bcdedit, Hyper-V features) may be limited." -ForegroundColor Yellow
    Write-Host "  For full diagnostics, right-click PowerShell -> Run as Administrator." -ForegroundColor Yellow
    Write-Host ""
}

# =============================================================================
# 1. WINDOWS VERSION
# =============================================================================
Write-SectionHeader "1" "Windows Version"

try {
    $ntInfo = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $displayVersion = $ntInfo.DisplayVersion
    $buildNumber = [int]$ntInfo.CurrentBuildNumber
    $ubr = [int]$ntInfo.UBR
    $fullBuild = "$buildNumber.$ubr"
    $productName = $ntInfo.ProductName

    Write-Info "Product: $productName"
    Write-Info "Version: $displayVersion (Build $fullBuild)"

    if ($buildNumber -lt $MinBuild -or ($buildNumber -eq $MinBuild -and $ubr -lt $MinUBR)) {
        Write-Warn "Build $fullBuild is older than recommended $MinBuild.$MinUBR"
        Write-Warn "Please update Windows to the latest version."
        $summary["Windows Version"] = @{ Status = "WARN"; Detail = "Build $fullBuild (update recommended)" }
        $actions += "Update Windows to build $MinBuild.$MinUBR or later via Settings > Windows Update."
    } else {
        Write-OK "Build $fullBuild meets the minimum requirement."
        $summary["Windows Version"] = @{ Status = "OK"; Detail = "Build $fullBuild" }
    }
} catch {
    Write-Err "Could not read Windows version from registry."
    $summary["Windows Version"] = @{ Status = "ERR"; Detail = "Could not read" }
}

# =============================================================================
# 2. WINDOWS ACTIVATION
# =============================================================================
Write-SectionHeader "2" "Windows Activation"

try {
    $licenseProducts = Get-CimInstance SoftwareLicensingProduct -Filter "Name like 'Windows%'" -ErrorAction Stop |
        Where-Object { $_.PartialProductKey }

    if ($licenseProducts) {
        $licenseStatus = $licenseProducts | Select-Object -First 1 -ExpandProperty LicenseStatus
        # LicenseStatus: 0=Unlicensed, 1=Licensed, 2=OOBGrace, 3=OOTGrace, 4=NonGenuineGrace, 5=Notification, 6=ExtendedGrace
        $statusMap = @{
            0 = "Unlicensed"
            1 = "Licensed (Activated)"
            2 = "Out-of-Box Grace Period"
            3 = "Out-of-Tolerance Grace Period"
            4 = "Non-Genuine Grace Period"
            5 = "Notification Mode"
            6 = "Extended Grace Period"
        }
        $statusText = if ($statusMap.ContainsKey($licenseStatus)) { $statusMap[$licenseStatus] } else { "Unknown ($licenseStatus)" }

        if ($licenseStatus -eq 1) {
            Write-OK "Windows is activated: $statusText"
            $summary["Windows Activation"] = @{ Status = "OK"; Detail = "Activated" }
        } else {
            Write-Warn "Windows is NOT fully activated: $statusText"
            Write-Warn "Some Cowork features may fail without proper activation."
            $summary["Windows Activation"] = @{ Status = "WARN"; Detail = $statusText }
            $actions += "Activate Windows with a valid license key via Settings > Activation."
        }
    } else {
        Write-Warn "No Windows license product found with a partial product key."
        $summary["Windows Activation"] = @{ Status = "WARN"; Detail = "No license found" }
        $actions += "Activate Windows with a valid license key."
    }
} catch {
    Write-Warn "Could not query license status (may need admin): $($_.Exception.Message)"
    $summary["Windows Activation"] = @{ Status = "WARN"; Detail = "Could not check" }
}

# =============================================================================
# 3. APP STORAGE LOCATION (CRITICAL CHECK)
# =============================================================================
Write-SectionHeader "3" "App Storage Location (CRITICAL)"

$appStorageProblem = $false
$claudePackagePath = Join-Path $env:LOCALAPPDATA "Packages\Claude_pzs8sxrjxfjjc"

if (Test-Path $claudePackagePath) {
    Write-Info "Found Claude package folder: $claudePackagePath"

    # Check for symlinks (ReparsePoints) inside the package folder
    try {
        $reparseItems = Get-ChildItem -Path $claudePackagePath -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint }

        if ($reparseItems -and $reparseItems.Count -gt 0) {
            Write-Err "Found symlinks (ReparsePoints) inside the Claude package folder!"

            foreach ($item in $reparseItems) {
                $target = $null
                try {
                    $target = (Get-Item $item.FullName -Force).Target
                } catch {
                    $target = "unknown target"
                }
                Write-Err "  -> $($item.Name) => $target"

                # Check if the symlink points to a different drive
                $itemDrive = (Split-Path $item.FullName -Qualifier)
                if ($target -and $target -is [string]) {
                    $targetDrive = if ($target -match '^([A-Z]:)') { $Matches[1] } else { $null }
                    if ($targetDrive -and $targetDrive -ne $itemDrive) {
                        $appStorageProblem = $true
                    }
                } elseif ($target -and $target -is [array]) {
                    foreach ($t in $target) {
                        $targetDrive = if ($t -match '^([A-Z]:)') { $Matches[1] } else { $null }
                        if ($targetDrive -and $targetDrive -ne $itemDrive) {
                            $appStorageProblem = $true
                        }
                    }
                }
            }

            if ($appStorageProblem) {
                Write-Host ""
                Write-Host "      !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red
                Write-Host "      !!  CRITICAL: App storage is redirected to another  !!" -ForegroundColor Red
                Write-Host "      !!  drive via symlinks! This is likely the cause of  !!" -ForegroundColor Red
                Write-Host "      !!  BOTH 'signature verification failed' AND         !!" -ForegroundColor Red
                Write-Host "      !!  'EXDEV: cross-device link not permitted' errors. !!" -ForegroundColor Red
                Write-Host "      !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red
                Write-Host ""
                Write-Err "Windows is configured to save new apps on a different drive."
                Write-Err "Claude's package data ends up on a separate volume, causing"
                Write-Err "cross-device link errors when the VM service tries to access it."
                $summary["App Storage Location"] = @{ Status = "ERR"; Detail = "Redirected to another drive (PROBLEM!)" }
                $actions += "CRITICAL: Change 'New apps will save to' back to C: in Settings > System > Storage > Advanced storage settings > Where new content is saved. Then uninstall and reinstall Claude Desktop."
            } else {
                Write-Warn "Symlinks found but they appear to be on the same drive."
                $summary["App Storage Location"] = @{ Status = "WARN"; Detail = "Symlinks found (same drive)" }
            }
        } else {
            Write-OK "No symlinks found in Claude package folder. Storage location looks correct."
            $summary["App Storage Location"] = @{ Status = "OK"; Detail = "C: drive (correct)" }
        }
    } catch {
        Write-Warn "Could not inspect Claude package folder contents: $($_.Exception.Message)"
        $summary["App Storage Location"] = @{ Status = "WARN"; Detail = "Could not inspect" }
    }
} else {
    Write-Info "Claude package folder not found at expected location."

    # Check if D:\WpSystem has Claude data (alternate symptom)
    $dWpSystem = "D:\WpSystem"
    $dClaudeFound = $false
    if (Test-Path $dWpSystem) {
        try {
            $dClaudeItems = Get-ChildItem -Path $dWpSystem -Recurse -Directory -Filter "Claude_pzs8sxrjxfjjc" -ErrorAction SilentlyContinue
            if ($dClaudeItems) {
                $dClaudeFound = $true
                Write-Err "Found Claude data on D: drive at: $($dClaudeItems[0].FullName)"
                Write-Err "This strongly suggests app storage is redirected to D:\"
                $appStorageProblem = $true
                $summary["App Storage Location"] = @{ Status = "ERR"; Detail = "D:\ drive (PROBLEM!)" }
                $actions += "CRITICAL: Change 'New apps will save to' back to C: in Settings > System > Storage > Advanced storage settings > Where new content is saved. Then uninstall and reinstall Claude Desktop."
            }
        } catch {
            # Ignore access errors on D:\WpSystem
        }
    }

    if (-not $dClaudeFound) {
        Write-Info "Claude may not be installed yet, or package folder uses a different suffix."
        $summary["App Storage Location"] = @{ Status = "OK"; Detail = "No issues detected" }
    }
}

# =============================================================================
# 4. HYPER-V STATUS
# =============================================================================
Write-SectionHeader "4" "Hyper-V Status"

$hyperVFeatures = @("Microsoft-Hyper-V", "VirtualMachinePlatform", "HypervisorPlatform")
$hyperVAllOK = $true

foreach ($feature in $hyperVFeatures) {
    try {
        $featureInfo = Get-WindowsOptionalFeature -Online -FeatureName $feature -ErrorAction Stop
        if ($featureInfo.State -eq "Enabled") {
            Write-OK "$feature : Enabled"
        } else {
            Write-Err "$feature : $($featureInfo.State)"
            $hyperVAllOK = $false
        }
    } catch {
        Write-Warn "$feature : Could not check (admin may be required)"
        $hyperVAllOK = $false
    }
}

if ($hyperVAllOK) {
    $summary["Hyper-V"] = @{ Status = "OK"; Detail = "All features enabled" }
} else {
    $summary["Hyper-V"] = @{ Status = "ERR"; Detail = "One or more features disabled/unknown" }
    $actions += "Enable Hyper-V features: Open PowerShell as Admin and run: Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All"
}

# =============================================================================
# 5. WSL2 STATUS
# =============================================================================
Write-SectionHeader "5" "WSL2 Status"

try {
    $wslOutput = & wsl --status 2>&1 | Out-String
    $wslText = $wslOutput

    if ($wslText -match "Default Version:\s*2" -or $wslText -match "version.*2" -or $wslText -match "WSL 2" -or $wslText -match "predeterminada:\s*2" -or $wslText -match "2") {
        Write-OK "WSL2 appears to be configured."
        $summary["WSL2"] = @{ Status = "OK"; Detail = "Installed" }
    } elseif ($wslText -match "not recognized" -or $wslText -match "is not installed") {
        Write-Err "WSL is not installed."
        $summary["WSL2"] = @{ Status = "ERR"; Detail = "Not installed" }
        $actions += "Install WSL2: Open PowerShell as Admin and run: wsl --install"
    } else {
        Write-Warn "WSL is installed but may not be version 2."
        Write-Info "WSL output: $($wslOutput | Select-Object -First 3 | Out-String)"
        $summary["WSL2"] = @{ Status = "WARN"; Detail = "Installed (version unclear)" }
        $actions += "Ensure WSL default version is 2: wsl --set-default-version 2"
    }
} catch {
    Write-Err "Could not run 'wsl --status': $($_.Exception.Message)"
    $summary["WSL2"] = @{ Status = "ERR"; Detail = "Could not check" }
    $actions += "Install WSL2: Open PowerShell as Admin and run: wsl --install"
}

# =============================================================================
# 6. HYPERVISOR LAUNCH TYPE
# =============================================================================
Write-SectionHeader "6" "Hypervisor Launch Type"

if ($isAdmin) {
    try {
        $bcdeditOutput = & bcdedit /enum 2>&1 | Out-String
        if ($bcdeditOutput -match "hypervisorlaunchtype\s+Auto") {
            Write-OK "Hypervisor launch type is set to Auto."
            $summary["Hypervisor Launch"] = @{ Status = "OK"; Detail = "Auto" }
        } elseif ($bcdeditOutput -match "hypervisorlaunchtype\s+(\w+)") {
            $launchType = $Matches[1]
            Write-Err "Hypervisor launch type is '$launchType' (should be 'Auto')."
            $summary["Hypervisor Launch"] = @{ Status = "ERR"; Detail = $launchType }
            $actions += "Set hypervisor launch type to Auto: Run as Admin: bcdedit /set hypervisorlaunchtype auto, then restart."
        } else {
            Write-Warn "Could not determine hypervisor launch type from bcdedit output."
            $summary["Hypervisor Launch"] = @{ Status = "WARN"; Detail = "Could not determine" }
        }
    } catch {
        Write-Warn "Could not run bcdedit: $($_.Exception.Message)"
        $summary["Hypervisor Launch"] = @{ Status = "WARN"; Detail = "Could not check" }
    }
} else {
    Write-Warn "Skipped: requires Administrator privileges."
    Write-Info "Re-run this script as Administrator to check hypervisor launch type."
    $summary["Hypervisor Launch"] = @{ Status = "WARN"; Detail = "Needs admin" }
}

# =============================================================================
# 7. CLAUDE DESKTOP INSTALLATION
# =============================================================================
Write-SectionHeader "7" "Claude Desktop Installation"

try {
    $claudePackage = Get-AppxPackage -Name "Claude" -ErrorAction SilentlyContinue

    if ($claudePackage) {
        Write-OK "Claude Desktop is installed."
        Write-Info "Version: $($claudePackage.Version)"
        Write-Info "Install Location: $($claudePackage.InstallLocation)"
        Write-Info "Package Full Name: $($claudePackage.PackageFullName)"
        $summary["Claude Desktop"] = @{ Status = "OK"; Detail = "v$($claudePackage.Version)" }
    } else {
        Write-Err "Claude Desktop is NOT installed (not found via Get-AppxPackage)."
        $summary["Claude Desktop"] = @{ Status = "ERR"; Detail = "Not installed" }
        $actions += "Install Claude Desktop from the Microsoft Store or https://claude.ai/download"
    }
} catch {
    Write-Warn "Could not check for Claude Desktop: $($_.Exception.Message)"
    $summary["Claude Desktop"] = @{ Status = "WARN"; Detail = "Could not check" }
}

# =============================================================================
# 8. COWORK VM SERVICE STATUS
# =============================================================================
Write-SectionHeader "8" "CoworkVMService Status"

try {
    $coworkService = Get-Service -Name "CoworkVMService" -ErrorAction Stop

    if ($coworkService.Status -eq "Running") {
        Write-OK "CoworkVMService is Running."
        $summary["CoworkVMService"] = @{ Status = "OK"; Detail = "Running" }
    } elseif ($coworkService.Status -eq "Stopped") {
        Write-Warn "CoworkVMService is Stopped."
        $summary["CoworkVMService"] = @{ Status = "WARN"; Detail = "Stopped" }
        $actions += "Start CoworkVMService: Open Services (services.msc) and start it, or run: Start-Service CoworkVMService"
    } else {
        Write-Warn "CoworkVMService status: $($coworkService.Status)"
        $summary["CoworkVMService"] = @{ Status = "WARN"; Detail = "$($coworkService.Status)" }
    }
} catch {
    Write-Info "CoworkVMService not found. This is normal if Cowork hasn't been set up yet."
    $summary["CoworkVMService"] = @{ Status = "WARN"; Detail = "Not found" }
}

# =============================================================================
# 9. COWORK SERVICE LOG
# =============================================================================
Write-SectionHeader "9" "Cowork Service Log"

$coworkLogPath = "C:\ProgramData\Claude\Logs\cowork-service.log"

if (Test-Path $coworkLogPath) {
    Write-Info "Log file found: $coworkLogPath"

    try {
        $logLines = Get-Content -Path $coworkLogPath -Tail 5 -ErrorAction Stop
        Write-Info "Last 5 lines:"
        foreach ($line in $logLines) {
            Write-Host "        $line" -ForegroundColor DarkGray
        }

        $fullLog = Get-Content -Path $coworkLogPath -Raw -ErrorAction SilentlyContinue

        # Check for known error patterns
        if ($fullLog -match "signature verification initialization failed") {
            Write-Err "Found 'signature verification initialization failed' in logs!"
            Write-Err "This is often caused by: outdated Windows, unactivated Windows,"
            Write-Err "or app storage redirected to a non-C: drive."
            $summary["Service Log"] = @{ Status = "ERR"; Detail = "Signature verification failed" }
            if ($actions -notcontains "Update Windows*") {
                $actions += "Check Windows activation, Windows updates, and app storage location (see items above)."
            }
        } elseif ($fullLog -match "EXDEV") {
            Write-Err "Found 'EXDEV: cross-device link not permitted' in logs!"
            Write-Err "This is caused by app storage being on a different drive than C:\"
            $summary["Service Log"] = @{ Status = "ERR"; Detail = "EXDEV cross-device error" }
        } elseif ($fullLog -match "VM started successfully") {
            Write-OK "Log shows 'VM started successfully' - Cowork appears functional!"
            $summary["Service Log"] = @{ Status = "OK"; Detail = "VM started OK" }
        } else {
            Write-Info "No known error patterns detected in the log."
            $summary["Service Log"] = @{ Status = "OK"; Detail = "No known errors" }
        }
    } catch {
        Write-Warn "Could not read log file: $($_.Exception.Message)"
        $summary["Service Log"] = @{ Status = "WARN"; Detail = "Could not read" }
    }
} else {
    Write-Info "Log file not found at $coworkLogPath (Cowork may not have run yet)."
    $summary["Service Log"] = @{ Status = "WARN"; Detail = "No log file" }
}

# =============================================================================
# 10. RESIDUAL FILES CHECK
# =============================================================================
Write-SectionHeader "10" "Residual Files Check"

$residualPaths = @(
    @{ Path = "$env:APPDATA\Claude";                     Label = "AppData\Roaming\Claude" },
    @{ Path = "$env:LOCALAPPDATA\Claude";                Label = "AppData\Local\Claude" },
    @{ Path = "C:\ProgramData\Claude";                   Label = "ProgramData\Claude" }
)

$residualsFound = @()

foreach ($entry in $residualPaths) {
    if (Test-Path $entry.Path) {
        $itemCount = (Get-ChildItem -Path $entry.Path -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object).Count
        Write-Info "Found: $($entry.Label) ($itemCount items)"
        $residualsFound += $entry.Label
    } else {
        Write-Info "Not found: $($entry.Label)"
    }
}

# Check D:\WpSystem for Claude residuals
$dDriveResidual = $false
if (Test-Path "D:\WpSystem") {
    try {
        $dItems = Get-ChildItem -Path "D:\WpSystem" -Recurse -Directory -Filter "Claude_pzs8sxrjxfjjc" -ErrorAction SilentlyContinue
        if ($dItems) {
            $dDriveResidual = $true
            foreach ($d in $dItems) {
                Write-Warn "Found residual on D: drive: $($d.FullName)"
                $residualsFound += "D:\WpSystem\...\Claude_pzs8sxrjxfjjc"
            }
        }
    } catch {
        # Ignore access errors
    }
}

if ($residualsFound.Count -gt 0) {
    $summary["Residual Files"] = @{ Status = "WARN"; Detail = "$($residualsFound.Count) locations" }
    if ($dDriveResidual) {
        $actions += "Remove Claude residual files from D:\WpSystem after changing app storage back to C: and reinstalling."
    }
} else {
    Write-Info "No residual Claude files found."
    $summary["Residual Files"] = @{ Status = "OK"; Detail = "Clean" }
}

# =============================================================================
# SUMMARY
# =============================================================================
Write-Host ""
Write-Host ""
Write-Host "  +=============================================+" -ForegroundColor Cyan
Write-Host "  |         DIAGNOSTIC SUMMARY                  |" -ForegroundColor Cyan
Write-Host "  +=============================================+" -ForegroundColor Cyan

foreach ($key in $summary.Keys) {
    $entry = $summary[$key]
    $status = $entry.Status
    $detail = $entry.Detail

    $icon = switch ($status) {
        "OK"   { "[OK]" }
        "WARN" { "[!!]" }
        "ERR"  { "[XX]" }
        default { "[??]" }
    }
    $color = switch ($status) {
        "OK"   { "Green" }
        "WARN" { "Yellow" }
        "ERR"  { "Red" }
        default { "Gray" }
    }

    $label = $key.PadRight(22)
    $detailPad = $detail

    Write-Host "  | " -ForegroundColor Cyan -NoNewline
    Write-Host "$icon " -ForegroundColor $color -NoNewline
    Write-Host "$label " -NoNewline
    Write-Host "$detailPad" -ForegroundColor $color -NoNewline
    # Pad to fill the box width
    $totalLen = 4 + 5 + 23 + $detailPad.Length
    $padNeeded = [Math]::Max(0, 46 - $totalLen)
    Write-Host (" " * $padNeeded) -NoNewline
    Write-Host "|" -ForegroundColor Cyan
}

Write-Host "  +=============================================+" -ForegroundColor Cyan

# =============================================================================
# RECOMMENDED ACTIONS
# =============================================================================
if ($actions.Count -gt 0) {
    Write-Host ""
    Write-Host "  RECOMMENDED ACTIONS:" -ForegroundColor Yellow
    Write-Host "  --------------------" -ForegroundColor Yellow
    for ($i = 0; $i -lt $actions.Count; $i++) {
        Write-Host "  $($i + 1). $($actions[$i])" -ForegroundColor White
    }
} else {
    Write-Host ""
    Write-Host "  No issues detected! Everything looks good." -ForegroundColor Green
}

Write-Host ""
Write-Host "  For the full fix guide, visit:" -ForegroundColor Cyan
Write-Host "  https://github.com/LozadAPP/claude-cowork-windows-fix" -ForegroundColor White
Write-Host ""
