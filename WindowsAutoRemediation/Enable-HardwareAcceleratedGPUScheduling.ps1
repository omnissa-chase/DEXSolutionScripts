<#
.SYNOPSIS
    Enable-HardwareAcceleratedGPUScheduling -- Enables HAGS to reduce CPU overhead from GPU workloads.

.DESCRIPTION
    Hardware-Accelerated GPU Scheduling (HAGS) offloads GPU memory management from the
    CPU to the GPU itself, reducing CPU overhead for applications with heavy GPU workloads
    (video, 3D, creative apps). Requires Windows 10 2004+ (Build 19041+) and a WDDM 2.7+
    compatible GPU driver.

    A reboot is required for the change to take effect. This script detects the current
    state and enables HAGS if supported but disabled. It does NOT trigger a reboot -- use
    the interactive reboot scripts in WindowsReboot/ to prompt the user.

    +------+--------------------------------------------+--------------------+
    | Step | Name                                       | Remediates On      |
    +------+--------------------------------------------+--------------------+
    |  1   | OS Version Compatibility                   | Failed (skip all)  |
    |  2   | GPU Driver WDDM Version                    | Warning            |
    |  3   | HAGS Registry State                        | Failed             |
    |  4   | Pending Reboot Flag                        | -- (informational) |
    +------+--------------------------------------------+--------------------+

    Each step returns @{ Status = 'Passed'|'Warning'|'Failed'; Message = '...' }

.NOTES
    Script Name  : Enable-HardwareAcceleratedGPUScheduling.ps1
    Version      : 1.0.0
    Architecture : x64 (HAGS is not applicable to x86 systems)
    Context      : System (HKLM registry write required)
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-07-10
    Timeout      : 30 seconds

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

# -- Constants -----------------------------------------------------------------
$HagsRegPath  = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
$HagsRegValue = 'HwSchMode'
$HagsEnabled  = 2   # 1 = disabled, 2 = enabled
$MinBuild     = 19041  # Windows 10 2004 (first build with HAGS support)

# -- Step Definitions ----------------------------------------------------------
$Steps = @(

    @{
        Name             = 'OS Version Compatibility'
        Order            = 1
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            $build = [System.Environment]::OSVersion.Version.Build
            if ($build -lt $MinBuild) {
                return @{
                    Status  = 'Failed'
                    Message = "OS build $build is below minimum $MinBuild (Windows 10 2004). HAGS not supported on this OS."
                }
            }
            $caption = (Get-WmiObject -Class Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
            return @{ Status = 'Passed'; Message = "OS compatible: $caption (build $build)" }
        }
        ResolutionScript = $null   # Cannot resolve -- OS requirement cannot be changed
    },

    @{
        Name             = 'GPU Driver WDDM Version'
        Order            = 2
        Enabled          = $true
        ResolveOnWarning = $false  # Driver updates require admin action via UEM -- informational warning only
        DetectionScript  = {
            # WDDM version is stored as a feature in the driver INF but the most accessible
            # proxy is the driver date and the GPU generation. Query display adapters and
            # check DriverVersion -- WDDM 2.7 shipped with drivers from mid-2020 onwards.
            $adapters = Get-WmiObject -Class Win32_VideoController -ErrorAction SilentlyContinue |
                Where-Object { $_.AdapterCompatibility -notmatch 'Microsoft' -and $_.Name -notmatch 'Remote|Virtual|Basic' }

            if (-not $adapters) {
                return @{
                    Status  = 'Warning'
                    Message = 'No discrete/integrated GPU found in WMI. HAGS may not apply to this device.'
                }
            }

            $adapterInfo = foreach ($a in $adapters) {
                "$($a.Name) [driver $($a.DriverVersion)]"
            }

            # Driver version format: Major.Minor.Build.Patch
            # WDDM 2.7 corresponds roughly to driver version 27.x.x on Intel,
            # 26.x.x on AMD, and 4xx.xx on NVIDIA. A precise check requires
            # parsing INF -- instead we flag very old drivers (pre-2020) as a warning.
            $oldDrivers = $adapters | Where-Object {
                $ver = $_.DriverVersion -as [version]
                $ver -and $ver.Major -lt 20   # heuristic: major < 20 suggests pre-2020 driver
            }

            if ($oldDrivers) {
                $names = ($oldDrivers.Name) -join ', '
                return @{
                    Status  = 'Warning'
                    Message = "Potentially outdated GPU driver detected on: $names. Verify WDDM 2.7+ support before enabling HAGS."
                }
            }

            return @{ Status = 'Passed'; Message = "GPU driver(s) appear current: $($adapterInfo -join '; ')" }
        }
        ResolutionScript = $null   # Driver updates must be deployed via UEM by an admin
    },

    @{
        Name             = 'HAGS Registry State'
        Order            = 3
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            $current = (Get-ItemProperty -Path $HagsRegPath -Name $HagsRegValue -ErrorAction SilentlyContinue).$HagsRegValue
            if ($current -eq $HagsEnabled) {
                return @{ Status = 'Passed'; Message = "HAGS is already enabled (HwSchMode = $current)" }
            }
            if ($null -eq $current) {
                return @{ Status = 'Failed'; Message = "HAGS registry value not present (defaults to disabled). Will create and enable." }
            }
            return @{ Status = 'Failed'; Message = "HAGS is disabled (HwSchMode = $current). Will enable." }
        }
        ResolutionScript = {
            # Ensure the key exists, then set HwSchMode = 2 (enabled)
            if (-not (Test-Path $HagsRegPath)) {
                New-Item -Path $HagsRegPath -Force | Out-Null
            }
            Set-ItemProperty -Path $HagsRegPath -Name $HagsRegValue -Value $HagsEnabled -Type DWord -Force
        }
    },

    @{
        Name             = 'Pending Reboot Flag'
        Order            = 4
        Enabled          = $true
        ResolveOnWarning = $false  # Informational only -- reboot managed externally
        DetectionScript  = {
            # Check if a reboot is already pending from a previous change (CBS, Windows Update, etc.)
            $cbsPending   = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
            $wuPending    = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired' -ErrorAction SilentlyContinue) -ne $null
            $fileRename   = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations

            # Check whether HAGS itself has a pending reboot (value set but not yet active)
            $hagsValue    = (Get-ItemProperty -Path $HagsRegPath -Name $HagsRegValue -ErrorAction SilentlyContinue).$HagsRegValue

            $reasons = @()
            if ($cbsPending)            { $reasons += 'CBS component servicing' }
            if ($wuPending)             { $reasons += 'Windows Update' }
            if ($fileRename)            { $reasons += 'pending file rename operations' }
            if ($hagsValue -eq $HagsEnabled) { $reasons += 'HAGS enabled (requires reboot to activate)' }

            if ($reasons.Count -gt 0) {
                return @{
                    Status  = 'Warning'
                    Message = "Reboot pending for: $($reasons -join ', '). Schedule a reboot to apply HAGS."
                }
            }
            return @{ Status = 'Passed'; Message = 'No pending reboot detected' }
        }
        ResolutionScript = $null   # Reboot scheduling handled by WindowsReboot scripts
    }
)

# -- Engine --------------------------------------------------------------------
$activeSteps = $Steps | Where-Object { $_.Enabled } | Sort-Object Order

# If OS is incompatible (step 1 fails), skip remaining steps
$osCheck = $null
try {
    $osResult = & ($Steps | Where-Object { $_.Order -eq 1 }).DetectionScript
    if ($osResult.Status -eq 'Failed') {
        Write-Host "`n-- Enable-HardwareAcceleratedGPUScheduling ----------------------" -ForegroundColor Cyan
        Write-Host "   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        Write-Host '----------------------------------------------------------------' -ForegroundColor Cyan
        Write-Host "`n  [Failed ] OS Version Compatibility: $($osResult.Message)" -ForegroundColor Red
        Write-Host "`n  HAGS is not supported on this operating system. No changes made." -ForegroundColor Yellow
        Write-Host '----------------------------------------------------------------' -ForegroundColor Cyan
        exit 1
    }
} catch { }

$results = New-Object 'System.Collections.Generic.List[PSCustomObject]'

Write-Host "`n-- Enable-HardwareAcceleratedGPUScheduling ----------------------" -ForegroundColor Cyan
Write-Host "   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')   Steps: $($activeSteps.Count)"
Write-Host '----------------------------------------------------------------' -ForegroundColor Cyan

foreach ($step in $activeSteps) {

    $status     = 'Failed'
    $message    = 'Detection script did not return a result.'
    $remediated = $false
    $remError   = ''

    # -- Detection ------------------------------------------------------------
    try {
        $result  = & $step.DetectionScript
        $status  = $result.Status
        $message = $result.Message
    } catch {
        $status  = 'Failed'
        $message = "Detection exception: $($_.Exception.Message)"
    }

    # -- Remediation ----------------------------------------------------------
    $shouldRemediate = ($status -eq 'Failed') -or
                       ($status -eq 'Warning' -and $step.ResolveOnWarning)

    if ($shouldRemediate -and $step.ResolutionScript) {
        try {
            & $step.ResolutionScript | Out-Null
            $remediated = $true
        } catch {
            $remError = $_.Exception.Message
        }
    }

    # -- Output ---------------------------------------------------------------
    $color = switch ($status) {
        'Passed'  { 'Green'  }
        'Warning' { 'Yellow' }
        'Failed'  { 'Red'    }
        default   { 'White'  }
    }
    $remNote = if ($remediated)   { '  -> Remediation ran' }
               elseif ($remError) { "  -> Remediation ERROR: $remError" }
               else               { '' }

    Write-Host "`n  [$($status.PadRight(7))] $($step.Name): $message$remNote" -ForegroundColor $color

    $results.Add([PSCustomObject]@{
        Order      = $step.Order
        Name       = $step.Name
        Status     = $status
        Message    = $message
        Remediated = $remediated
        RemError   = $remError
    })
}

# -- Summary -------------------------------------------------------------------
$passed   = ($results | Where-Object { $_.Status -eq 'Passed'  }).Count
$warnings = ($results | Where-Object { $_.Status -eq 'Warning' }).Count
$failed   = ($results | Where-Object { $_.Status -eq 'Failed'  }).Count
$remCount = ($results | Where-Object { $_.Remediated }).Count

Write-Host "`n----------------------------------------------------------------" -ForegroundColor Cyan
Write-Host "  Passed: $passed  |  Warnings: $warnings  |  Failed: $failed  |  Remediations run: $remCount"
Write-Host "`n----------------------------------------------------------------" -ForegroundColor Cyan
Write-Host ''

# Exit 0 even if warnings -- HAGS pending reboot (step 4 warning) is expected after enabling
if ($failed -gt 0) { exit 1 }
exit 0
