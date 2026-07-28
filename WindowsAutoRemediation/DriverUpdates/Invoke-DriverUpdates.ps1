<#
.SYNOPSIS
    Invoke-DriverUpdates -- Windows Update driver discovery and installation.

.DESCRIPTION
    Queries Windows Update for available driver updates, optionally filters by
    title regex, and (in Install mode) downloads and installs them. Reboot state
    is detected via three independent signals and reported via exit code only --
    the script never forces a reboot.

    +---------+-----------------------------+--------------------------------+
    | Phase   | Name                        | Notes                          |
    +---------+-----------------------------+--------------------------------+
    |    1    | Pre-flight Checks           | Admin context, WU service      |
    |    2    | Driver Discovery            | WU search, filter + cap        |
    |    3    | Detect Report (Detect mode) | Exits 0=none, 1=found          |
    |    4    | Download                    | Stages update packages         |
    |    5    | Install                     | Applies staged drivers         |
    |    6    | Reboot Detection            | COM + registry + PendingRename |
    |    7    | Summary Report              | 0=OK, 3010=reboot, 1=error     |
    +---------+-----------------------------+--------------------------------+

    Exit codes (Detect mode):
        0    -- No driver updates available.
        1    -- Driver updates available (non-compliant; MDM triggers Install run).

    Exit codes (Install mode):
        0    -- All updates installed. No reboot signal, or AllowReboot=$false.
        1    -- One or more updates failed, or a script/environment error occurred.
        3010 -- All updates installed. Reboot required (AllowReboot=$true).

.PARAMETER Mode
    Detect  -- Report available driver updates and exit without installing.
    Install -- Download and install available driver updates.
    Accepts env var: $env:Mode.  Default: 'Detect'.

.PARAMETER DriverFilter
    Optional regex applied to driver Title before acting. Case-insensitive.
        -DriverFilter 'Intel|Realtek'   -- Intel or Realtek drivers only
        -DriverFilter 'NVIDIA.*Display' -- NVIDIA display adapters only
    Accepts env var: $env:DriverFilter.  Default: '' (all available drivers).

.PARAMETER AllowReboot
    When $true, the script returns exit code 3010 if any reboot signal is
    detected post-install so the calling system (SmartReboot / DEX) can schedule
    a reboot. High-risk driver classes (audio, GPU, USB, chipset, storage) also
    force the reboot flag when the WU COM result incorrectly reports
    RebootRequired=false (the INF reboot-lying problem).
    When $false, the script exits 0 on success regardless of reboot signals
    but still logs a reboot recommendation in output.
    Accepts env var: $env:AllowReboot.  Default: $false.

.PARAMETER MaxUpdates
    Safety cap on the number of updates processed per run. Prevents accidental
    bulk installs on endpoints with a large backlog.
    Accepts env var: $env:MaxUpdates.  Default: 10.

.NOTES
    Script Name  : Invoke-DriverUpdates.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-07-28
    Timeout      : 120 seconds

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

param(
    [ValidateSet('Detect', 'Install')]
    [string]$Mode         = $(if ($env:Mode)         { $env:Mode }                                        else { 'Detect' }),
    [string]$DriverFilter = $(if ($env:DriverFilter) { $env:DriverFilter }                               else { '' }),
    [bool]  $AllowReboot  = $(if ($env:AllowReboot)  { [System.Convert]::ToBoolean($env:AllowReboot) }   else { $false }),
    [int]   $MaxUpdates   = $(if ($env:MaxUpdates)   { [int]$env:MaxUpdates }                            else { 10 })
)

# Driver classes where WU COM incorrectly reports RebootRequired=false.
# Any installed driver whose Title matches will have the reboot flag set,
# regardless of what the COM API returns.
$HighRiskPatterns = @(
    'audio|sound|speaker|headset|realtek.*audio|conexant|IDT|Intel.*Smart Sound'
    'display adapter|video controller|nvidia|amd.*radeon|intel.*uhd|intel.*iris|geforce|quadro'
    'usb.*host controller|xhci|thunderbolt|displaylink'
    'ahci|nvme|sata.*controller|storage controller|intel.*rst|amd.*raid'
    'smbus|system management bus|intel.*management engine|intel.*serial io|amd.*psp|chipset'
)

# -- Phase 1: Pre-flight -------------------------------------------------------
Write-Host "-- Invoke-DriverUpdates ($Mode) --------------------------------------------------"

$currentPrincipal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error 'This script must run as Administrator or SYSTEM.'
    exit 1
}

$wuService = Get-Service -Name wuauserv -ErrorAction SilentlyContinue
if (-not $wuService) {
    Write-Error 'Windows Update service (wuauserv) not found on this system.'
    exit 1
}
if ($wuService.Status -ne 'Running') {
    Write-Host 'Windows Update service is not running. Attempting to start...'
    try {
        Start-Service -Name wuauserv -ErrorAction Stop
        Start-Sleep -Seconds 3
    } catch {
        Write-Error "Failed to start Windows Update service: $_"
        exit 1
    }
}

# -- Phase 2: Driver Discovery -------------------------------------------------
$wuSession    = $null
$searchResult = $null

try {
    $wuSession = New-Object -ComObject Microsoft.Update.Session
    $wuSession.ClientApplicationID = 'DEX-DriverUpdate'
    $searcher = $wuSession.CreateUpdateSearcher()
    Write-Host 'Searching Windows Update for available driver updates...'
    $searchResult = $searcher.Search("IsInstalled=0 and Type='Driver'")
} catch {
    $hr = '0x{0:X8}' -f ($_.Exception.HResult)
    Write-Error "Windows Update search failed ($hr): $_"
    if ($_.Exception.HResult -eq -2145124284) {
        # 0x80240044 -- WU session busy (another WU process is active)
        Write-Host 'Hint: Another Windows Update session may be active. Retry after it completes.'
    }
    exit 1
}

$allDrivers = $searchResult.Updates

# Apply DriverFilter
if ($DriverFilter) {
    $filtered = @($allDrivers | Where-Object { $_.Title -match $DriverFilter })
    Write-Host "DriverFilter '$DriverFilter': $($filtered.Count) of $($allDrivers.Count) update(s) matched."
} else {
    $filtered = @($allDrivers)
    Write-Host "$($allDrivers.Count) driver update(s) found."
}

if ($filtered.Count -eq 0) {
    Write-Host 'No driver updates to act on.'
    exit 0
}

# Apply MaxUpdates safety cap
if ($filtered.Count -gt $MaxUpdates) {
    Write-Warning "$($filtered.Count) available updates exceed MaxUpdates cap ($MaxUpdates). Processing first $MaxUpdates only."
    $filtered = $filtered | Select-Object -First $MaxUpdates
}

# Print discovery list
Write-Host ''
foreach ($drv in $filtered) {
    $rr  = if ($drv.RebootRequired) { '[RebootReq]' } else { '[NoReboot] ' }
    $ver = [string]$drv.DriverVerDate
    Write-Host "  $rr $($drv.Title)$(if ($ver) { "  [$ver]" })"
}
Write-Host ''

# -- Phase 3: Detect mode exit -------------------------------------------------
if ($Mode -eq 'Detect') {
    Write-Host "$($filtered.Count) driver update(s) available. Run with -Mode Install to apply."
    exit 1
}

# -- Phase 4: Download ---------------------------------------------------------
Write-Host 'Downloading...'
$toDownload = New-Object -ComObject Microsoft.Update.UpdateColl
foreach ($drv in $filtered) { [void]$toDownload.Add($drv) }

try {
    $downloader         = $wuSession.CreateUpdateDownloader()
    $downloader.Updates = $toDownload
    $dlResult           = $downloader.Download()
    Write-Host ('Download finished.  ResultCode: {0}  HResult: 0x{1:X8}' -f $dlResult.ResultCode, $dlResult.HResult)
} catch {
    $hr = '0x{0:X8}' -f ($_.Exception.HResult)
    Write-Error "Download failed ($hr): $_"
    exit 1
}

# -- Phase 5: Install ----------------------------------------------------------
Write-Host 'Installing...'
$toInstall = New-Object -ComObject Microsoft.Update.UpdateColl
foreach ($drv in $filtered) {
    if ($drv.IsDownloaded) {
        # Accept any pending EULA silently (required before install)
        if (-not $drv.EulaAccepted) { $drv.AcceptEula() }
        [void]$toInstall.Add($drv)
    }
}

if ($toInstall.Count -eq 0) {
    Write-Error 'No updates downloaded successfully. Cannot install.'
    exit 1
}

$installResult = $null
try {
    $installer         = $wuSession.CreateUpdateInstaller()
    $installer.Updates = $toInstall
    $installResult     = $installer.Install()
} catch {
    $hr = '0x{0:X8}' -f ($_.Exception.HResult)
    Write-Error "Install call failed ($hr): $_"
    exit 1
}

# Per-driver result reporting
$installedCount = 0
$failedCount    = 0
$rebootNeeded   = $installResult.RebootRequired   # Signal 1: COM collection-level result

Write-Host ''
Write-Host 'Install results:'
for ($i = 0; $i -lt $toInstall.Count; $i++) {
    $drv        = $toInstall.Item($i)
    $itemResult = $installResult.GetUpdateResult($i)
    $succeeded  = $itemResult.ResultCode -eq 2     # orcSucceeded

    $label = if ($succeeded) { '[OK]    ' } else { '[FAILED]' }
    $rrTag = if ($itemResult.RebootRequired) { '[RebootReq]' } else { '[NoReboot] ' }
    Write-Host "  $label $rrTag $($drv.Title)"

    if ($succeeded) {
        $installedCount++
        if ($itemResult.RebootRequired) { $rebootNeeded = $true }

        # High-risk class check: override false RebootRequired for known-lying driver classes
        foreach ($pattern in $HighRiskPatterns) {
            if ($drv.Title -match $pattern) {
                if (-not $itemResult.RebootRequired) {
                    Write-Host '           ^ High-risk class: reboot override applied (WU reported NoReboot).'
                }
                $rebootNeeded = $true
                break
            }
        }
    } else {
        $failedCount++
        Write-Host ('           HRESULT: 0x{0:X8}' -f $itemResult.HResult)
    }
}
Write-Host ''

# -- Phase 6: Reboot Detection -------------------------------------------------
# Signal 2: WU registry reboot pending key
if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
    Write-Host 'Reboot signal: WU registry key present.'
    $rebootNeeded = $true
}

# Signal 3: OS-level pending file replacement queue (set when kernel files are staged)
$pendingRenames = (Get-ItemProperty `
    -Path  'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' `
    -Name  PendingFileRenameOperations `
    -ErrorAction SilentlyContinue).PendingFileRenameOperations
if ($pendingRenames) {
    Write-Host 'Reboot signal: PendingFileRenameOperations present.'
    $rebootNeeded = $true
}

# -- Phase 7: Summary Report ---------------------------------------------------
Write-Host "Summary: $installedCount installed, $failedCount failed, RebootRequired: $rebootNeeded"

if ($failedCount -gt 0) {
    Write-Host 'One or more driver updates failed to install. Check HRESULT values above.'
    exit 1
}

if ($rebootNeeded) {
    if ($AllowReboot) {
        Write-Host 'Reboot required. Signaling exit 3010 for SmartReboot / DEX scheduling.'
        exit 3010
    } else {
        Write-Host 'Reboot recommended but AllowReboot=$false. Exiting 0 -- schedule a reboot separately.'
        exit 0
    }
}

Write-Host 'All driver updates installed successfully. No reboot required.'
exit 0
