<#
.SYNOPSIS
    Invoke-AutoRemediateWindowsUpdates -- Automated Windows Update diagnostic and remediation.

.DESCRIPTION
    Runs a hard-coded sequence of Windows Update health checks and automatically
    executes the corresponding remediation for any step that fails (or warns,
    when ResolveOnWarning is set). Fully self-contained -- no JSON, no UI, no
    external dependencies. Designed for deployment as a Workspace ONE MDM
    remediation script or standalone admin tool.

    +------+----------------------------------+----------------------------------+
    | Step | Name                             | Remediates On                    |
    +------+----------------------------------+----------------------------------+
    |  1   | Windows Update Service           | Failed, Warning (ResolveOnWarn)  |
    |  2   | BITS Service                     | Failed                           |
    |  3   | Cryptographic Services           | Failed                           |
    |  4   | Windows Update DataStore         | Warning (ResolveOnWarning)       |
    |  5   | Pending Reboot Check             | -- (informational only)           |
    |  6   | Windows Update Policy            | -- (informational only)           |
    |  7   | Disk Space for Updates           | Failed, Warning (ResolveOnWarn)  |
    |  8   | Last Update Date                 | -- (informational only)           |
    +------+----------------------------------+----------------------------------+

    Each step returns @{ Status = 'Passed'|'Warning'|'Failed'; Message = '...' }
    Resolution scripts run silently; errors are captured and reported at the end.

.NOTES
    Script Name  : Invoke-AutoRemediateWindowsUpdates.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-07-10
    Timeout      : 30 seconds

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

# -- Step Definitions ----------------------------------------------------------
# Only supported fields: Name, Order, Enabled, ResolveOnWarning,
#                        DetectionScript, ResolutionScript
$Steps = @(

    @{
        Name             = 'Windows Update Service'
        Order            = 1
        Enabled          = $true
        ResolveOnWarning = $true   # Service in a bad startup state returns Warning -- still remediate
        DetectionScript  = {
            $svc = Get-Service -Name wuauserv -ErrorAction SilentlyContinue
            if (-not $svc) {
                return @{ Status = 'Failed'; Message = 'Windows Update service (wuauserv) not found' }
            }
            if ($svc.StartType -eq 'Disabled') {
                return @{ Status = 'Failed'; Message = 'Windows Update service is Disabled' }
            }
            if ($svc.Status -eq 'Running') {
                return @{ Status = 'Passed'; Message = "wuauserv: $($svc.Status) / $($svc.StartType)" }
            }
            return @{ Status = 'Warning'; Message = "wuauserv: $($svc.Status) / $($svc.StartType) -- will restart" }
        }
        ResolutionScript = {
            Set-Service  -Name wuauserv -StartupType Manual  -ErrorAction SilentlyContinue
            Stop-Service -Name wuauserv -Force               -ErrorAction SilentlyContinue
            Start-Service -Name wuauserv                     -ErrorAction SilentlyContinue
        }
    },

    @{
        Name             = 'BITS Service'
        Order            = 2
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            # BITS (Background Intelligent Transfer Service) is the download engine for Windows Update
            $svc = Get-Service -Name BITS -ErrorAction SilentlyContinue
            if (-not $svc) {
                return @{ Status = 'Failed'; Message = 'BITS service not found' }
            }
            if ($svc.StartType -eq 'Disabled') {
                return @{ Status = 'Failed'; Message = 'BITS is Disabled -- update downloads will fail' }
            }
            return @{ Status = 'Passed'; Message = "BITS: $($svc.Status) / $($svc.StartType)" }
        }
        ResolutionScript = {
            Set-Service  -Name BITS -StartupType Manual -ErrorAction SilentlyContinue
            Start-Service -Name BITS                    -ErrorAction SilentlyContinue
        }
    },

    @{
        Name             = 'Cryptographic Services'
        Order            = 3
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            # CryptSvc is required for update package signature verification
            $svc = Get-Service -Name CryptSvc -ErrorAction SilentlyContinue
            if (-not $svc) {
                return @{ Status = 'Failed'; Message = 'Cryptographic Services (CryptSvc) not found' }
            }
            if ($svc.Status -eq 'Running') {
                return @{ Status = 'Passed'; Message = 'CryptSvc is running' }
            }
            return @{ Status = 'Failed'; Message = "CryptSvc is $($svc.Status) -- update verification will fail" }
        }
        ResolutionScript = {
            Start-Service -Name CryptSvc -ErrorAction SilentlyContinue
        }
    },

    @{
        Name             = 'Windows Update DataStore'
        Order            = 4
        Enabled          = $true
        # DataStore issues present as Warning -- remediate by stopping services,
        # clearing the store, and restarting so it rebuilds cleanly.
        ResolveOnWarning = $true
        DetectionScript  = {
            $datastore = "$env:SystemRoot\SoftwareDistribution\DataStore"
            $db        = Join-Path $datastore 'DataStore.edb'

            if (-not (Test-Path $datastore)) {
                return @{ Status = 'Warning'; Message = 'SoftwareDistribution\DataStore folder missing' }
            }
            if (-not (Test-Path $db)) {
                return @{ Status = 'Warning'; Message = 'DataStore.edb missing -- will rebuild on next cycle' }
            }
            $sizeMB = [math]::Round((Get-Item $db).Length / 1MB, 1)
            if ($sizeMB -gt 500) {
                return @{ Status = 'Warning'; Message = "DataStore.edb is bloated ($($sizeMB)MB) -- clearing" }
            }
            return @{ Status = 'Passed'; Message = "DataStore.edb present and healthy ($($sizeMB)MB)" }
        }
        ResolutionScript = {
            # Stop update services, purge the DataStore, restart -- Windows rebuilds it automatically
            Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
            Stop-Service -Name BITS     -Force -ErrorAction SilentlyContinue
            Remove-Item "$env:SystemRoot\SoftwareDistribution\DataStore\*" `
                -Recurse -Force -ErrorAction SilentlyContinue
            Start-Service -Name BITS     -ErrorAction SilentlyContinue
            Start-Service -Name wuauserv -ErrorAction SilentlyContinue
        }
    },

    @{
        Name             = 'Pending Reboot Check'
        Order            = 5
        Enabled          = $true
        ResolveOnWarning = $false   # Cannot auto-reboot -- informational only
        DetectionScript  = {
            # Check all three common pending-reboot registry indicators
            $pending = $false

            if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
                $pending = $true
            }
            if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
                $pending = $true
            }
            $pfro = Get-ItemProperty `
                -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' `
                -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
            if ($pfro) { $pending = $true }

            if ($pending) {
                return @{ Status = 'Warning'; Message = 'System has a pending reboot -- reboot required before further updates' }
            }
            return @{ Status = 'Passed'; Message = 'No pending reboot detected' }
        }
        ResolutionScript = $null   # Intentionally no auto-remediation -- admin must schedule reboot
    },

    @{
        Name             = 'Windows Update Policy'
        Order            = 6
        Enabled          = $true
        ResolveOnWarning = $false   # Policy source is informational -- cannot auto-fix GPO
        DetectionScript  = {
            $wuPath  = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
            $auPath  = "$wuPath\AU"
            $server  = (Get-ItemProperty -Path $wuPath -Name WUServer    -ErrorAction SilentlyContinue).WUServer
            $useWU   = (Get-ItemProperty -Path $auPath -Name UseWUServer  -ErrorAction SilentlyContinue).UseWUServer

            if ($server -and $useWU -eq 1) {
                return @{ Status = 'Passed'; Message = "Managed update source: $server" }
            }
            if ($server -and $useWU -ne 1) {
                return @{ Status = 'Warning'; Message = 'WSUS server configured but UseWUServer is disabled' }
            }
            return @{ Status = 'Warning'; Message = 'No WSUS/SCCM policy -- updates sourced directly from Microsoft' }
        }
        ResolutionScript = $null   # Intentionally no auto-remediation -- requires GPO or IT intervention
    },

    @{
        Name             = 'Disk Space for Updates'
        Order            = 7
        Enabled          = $true
        ResolveOnWarning = $true   # Low disk triggers Disk Cleanup to free space
        DetectionScript  = {
            $drive = Get-PSDrive -Name C -ErrorAction SilentlyContinue
            if (-not $drive) {
                return @{ Status = 'Warning'; Message = 'Unable to query C: drive free space' }
            }
            $freeGB = [math]::Round($drive.Free / 1GB, 1)
            if ($freeGB -lt 5) {
                return @{ Status = 'Failed'; Message = "Only $($freeGB)GB free on C: -- updates require at least 5GB" }
            }
            if ($freeGB -lt 10) {
                return @{ Status = 'Warning'; Message = "$($freeGB)GB free on C: -- low, may affect large updates" }
            }
            return @{ Status = 'Passed'; Message = "$($freeGB)GB free on C:" }
        }
        ResolutionScript = {
            # Run Disk Cleanup silently against C: to recover what space is possible
            Start-Process -FilePath 'cleanmgr.exe' -ArgumentList '/sagerun:1' -Wait -ErrorAction SilentlyContinue
        }
    },

    @{
        Name             = 'Last Update Date'
        Order            = 8
        Enabled          = $true
        ResolveOnWarning = $false   # Informational -- cannot force an update install silently
        DetectionScript  = {
            try {
                $session    = New-Object -ComObject 'Microsoft.Update.Session' -ErrorAction Stop
                $searcher   = $session.CreateUpdateSearcher()
                $count      = $searcher.GetTotalHistoryCount()
                if ($count -eq 0) {
                    return @{ Status = 'Warning'; Message = 'No Windows Update history found on this device' }
                }
                $history     = $searcher.QueryHistory(0, [Math]::Min($count, 50))
                $lastSuccess = $history | Where-Object { $_.ResultCode -eq 2 } | Select-Object -First 1
                if (-not $lastSuccess) {
                    return @{ Status = 'Warning'; Message = 'No successful updates found in recent history' }
                }
                $days    = [int]((Get-Date) - $lastSuccess.Date).TotalDays
                $dateStr = $lastSuccess.Date.ToString('yyyy-MM-dd')
                if ($days -gt 60) {
                    return @{ Status = 'Warning'; Message = "Last successful update was $days days ago ($dateStr)" }
                }
                return @{ Status = 'Passed'; Message = "Last update: $dateStr ($days days ago)" }
            } catch {
                return @{ Status = 'Warning'; Message = "Unable to query update history: $($_.Exception.Message)" }
            }
        }
        ResolutionScript = $null   # Intentionally no auto-remediation -- update install requires user scheduling
    }
)

# -- Execution Engine ----------------------------------------------------------
$activeSteps = $Steps |
    Where-Object { $_.Enabled } |
    Sort-Object   { [int]$_.Order }

$results = New-Object 'System.Collections.Generic.List[PSCustomObject]'

Write-Host "`n-- Invoke-AutoRemediateWindowsUpdates ---------------------------" -ForegroundColor Cyan
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

if ($failed -gt 0) { exit 1 }
exit 0
