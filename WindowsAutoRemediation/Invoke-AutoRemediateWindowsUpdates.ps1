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
    Resolution scripts run silently; a script may return one line of text, which is
    shown beside its result. Errors are captured and reported at the end.

    Step 7 treats low disk as the reason a device is unpatched, not as a note. It
    frees space itself, in tiers, cheapest and safest first, and stops as soon as
    free space is back above the warning line:
      Tier 1  on Warning or Failed. Regenerable data nobody will miss: temp files
              older than a week, crash dumps and error reports, VS Code caches,
              leftover versions of Squirrel-updated apps, Delivery Optimization.
      Tier 2  on Failed only. Caches that cost the user a re-download: package
              manager caches, browser caches, every profile's Recycle Bin.
      Tier 3  still Failed after that. Windows Disk Cleanup with Update Cleanup and
              Previous Installations, started in the background because it runs
              for minutes. Same categories as DiskCleanup\Start-DiskCleanup.ps1.
    Per-user targets follow the same rules as Invoke-AutoRemediateProfileBloat.ps1:
    never Documents, Desktop or Downloads, and a locked file is skipped, not forced.

.NOTES
    Script Name  : Invoke-AutoRemediateWindowsUpdates.ps1
    Version      : 1.1.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-10-28
    Timeout      : 60 seconds (step 7 holds itself to 40 of them)

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

# -- Disk Space (step 7) -------------------------------------------------------
# A cumulative update needs a few GB to stage and a feature update closer to 20 GB.
# The previous remediation ran `cleanmgr /sagerun:1`, which deletes nothing unless
# profile 1 was first configured with /sageset, and can run for minutes against a
# 30 second script timeout. This replaces it with a deterministic, time-boxed cleanup.
$DiskMinFreeGB            = 5    # Failed below this: an update cannot stage at all
$DiskWarnFreeGB           = 10   # Warning below this: large updates at risk. Also the cleanup target.
$DiskStaleDays            = 7    # a temp file younger than this may belong to a live session
$DiskCleanupBudgetSeconds = 40   # leaves the other seven steps room inside the 60 s timeout

function Get-DiskFreeGB {
    return [math]::Round((Get-PSDrive -Name C -ErrorAction Stop).Free / 1GB, 1)
}

function Get-CleanupProfilePaths {
    # Joins each relative path onto every non-special profile on the device, the same
    # selection Invoke-AutoRemediateProfileBloat.ps1 makes.
    param([string[]]$RelativePaths)
    $profiles = @(Get-CimInstance -ClassName Win32_UserProfile -ErrorAction SilentlyContinue |
                  Where-Object { -not $_.Special -and $_.LocalPath -and (Test-Path -LiteralPath $_.LocalPath) })
    foreach ($p in $profiles) {
        foreach ($rel in $RelativePaths) { Join-Path $p.LocalPath $rel }
    }
}

function Get-SquirrelLeftoverVersions {
    # Squirrel-installed apps (GitHub Desktop, Discord, Postman, classic Teams) keep every
    # app-x.y.z folder they ever updated through, hundreds of MB each. Only the newest
    # is in use. An app is recognised by the Update.exe that Squirrel drops beside them.
    foreach ($local in (Get-CleanupProfilePaths 'AppData\Local')) {
        foreach ($app in (Get-ChildItem -LiteralPath $local -Directory -ErrorAction SilentlyContinue)) {
            if (-not (Test-Path -LiteralPath (Join-Path $app.FullName 'Update.exe'))) { continue }
            $versions = @(Get-ChildItem -LiteralPath $app.FullName -Directory -Filter 'app-*' -ErrorAction SilentlyContinue |
                          Sort-Object { try { [version]($_.Name -replace '^app-', '') } catch { [version]'0.0' } } -Descending)
            if ($versions.Count -gt 1) { $versions[1..($versions.Count - 1)].FullName }
        }
    }
}

function Remove-CleanupTarget {
    # Deletes the files under each path (wildcards allowed), optionally only those older
    # than AgeDays, and returns the bytes actually freed. A file that will not delete is
    # in use by something running; it is a cache, so it is left to age out, not forced.
    param([string[]]$Paths, [int]$AgeDays = 0, [switch]$RemoveFolder)
    $cutoff = (Get-Date).AddDays(-$AgeDays)
    $bytes  = 0
    foreach ($path in $Paths) {
        foreach ($item in (Resolve-Path -Path $path -ErrorAction SilentlyContinue)) {
            Get-ChildItem -LiteralPath $item.ProviderPath -Recurse -File -Force -ErrorAction SilentlyContinue |
                Where-Object { $AgeDays -eq 0 -or $_.LastWriteTime -lt $cutoff } |
                ForEach-Object {
                    $size = $_.Length
                    try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop; $bytes += $size } catch { }
                }
            if ($RemoveFolder) { Remove-Item -LiteralPath $item.ProviderPath -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
    return $bytes
}

# What gets cleaned, in the order it is tried. Paths is evaluated at run time so profile
# enumeration only happens when the step actually fires. Nothing here holds documents,
# credentials, bookmarks, history or mail data.
$DiskCleanupCatalog = @(
    @{ Tier = 1; Label = 'Windows temp'; AgeDays = $DiskStaleDays
       Paths = { "$env:SystemRoot\Temp" } }
    @{ Tier = 1; Label = 'user temp'; AgeDays = $DiskStaleDays
       Paths = { Get-CleanupProfilePaths 'AppData\Local\Temp' } }
    @{ Tier = 1; Label = 'crash dumps and error reports'
       Paths = { @("$env:SystemRoot\MEMORY.DMP", "$env:SystemRoot\Minidump",
                   "$env:ProgramData\Microsoft\Windows\WER\ReportQueue",
                   "$env:ProgramData\Microsoft\Windows\WER\ReportArchive") +
                 @(Get-CleanupProfilePaths 'AppData\Local\CrashDumps') } }
    @{ Tier = 1; Label = 'VS Code caches'
       Paths = { Get-CleanupProfilePaths 'AppData\Roaming\Code\CachedExtensionVSIXs',
                                         'AppData\Roaming\Code\logs',
                                         'AppData\Roaming\Code\CachedData' } }
    @{ Tier = 1; Label = 'old Squirrel app versions'; RemoveFolder = $true
       Paths = { Get-SquirrelLeftoverVersions } }
    @{ Tier = 1; Label = 'Delivery Optimization cache'
       Action = { if (Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue) {
                      Delete-DeliveryOptimizationCache -Force -ErrorAction SilentlyContinue } } }
    @{ Tier = 2; Label = 'package manager caches'
       Paths = { Get-CleanupProfilePaths '.nuget\packages', 'AppData\Local\NuGet\v3-cache',
                                         'AppData\Local\npm-cache', 'AppData\Local\pip\cache',
                                         'AppData\Local\Yarn\Cache', '.gradle\caches' } }
    @{ Tier = 2; Label = 'browser caches'
       Paths = { Get-CleanupProfilePaths 'AppData\Local\Google\Chrome\User Data\*\Cache',
                                         'AppData\Local\Google\Chrome\User Data\*\Code Cache',
                                         'AppData\Local\Microsoft\Edge\User Data\*\Cache',
                                         'AppData\Local\Microsoft\Edge\User Data\*\Code Cache',
                                         'AppData\Local\Mozilla\Firefox\Profiles\*\cache2' } }
    @{ Tier = 2; Label = 'Recycle Bins'
       Paths = { Get-ChildItem -LiteralPath "$env:SystemDrive\`$Recycle.Bin" -Directory -Force -ErrorAction SilentlyContinue |
                 ForEach-Object { $_.FullName } } }
)

function Start-WindowsDiskCleanupInBackground {
    # Tier 3. Same profile id and the core categories of DiskCleanup\Start-DiskCleanup.ps1.
    # Update Cleanup hands superseded component-store files to the Windows Modules
    # Installer, which is where most of the space on a long-patched device comes back,
    # and which takes minutes. So it is started and left running; the next run of this
    # script reports the result. Returns $false when cleanmgr is not on this SKU.
    $profileId  = 55
    $categories = @('Update Cleanup', 'Previous Installations', 'Windows Upgrade Log Files',
                    'System error memory dump files', 'System error minidump files',
                    'Windows Error Reporting Files', 'Temporary Files')
    $root = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
    foreach ($key in (Get-ChildItem -Path $root -ErrorAction SilentlyContinue)) {
        $value = if ($key.PSChildName -in $categories) { 2 } else { 0 }
        New-ItemProperty -Path $key.PSPath -Name "StateFlags00$profileId" -Value $value -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
    }
    if (-not (Get-Command cleanmgr.exe -ErrorAction SilentlyContinue)) { return $false }
    Start-Process -FilePath 'cleanmgr.exe' -ArgumentList "/sagerun:$profileId" -WindowStyle Hidden -ErrorAction SilentlyContinue
    return $true
}

function Invoke-DiskCleanup {
    # Works through the catalog up to MaxTier and returns a one-line account of what it
    # freed. Tier 2 costs the user a re-download, so it takes only what is needed to get
    # back above the warning line. The time budget keeps the step inside the script timeout.
    param([int]$MaxTier)
    $stopwatch  = [System.Diagnostics.Stopwatch]::StartNew()
    $totalBytes = 0
    $freed      = @()
    $stoppedBy  = ''
    foreach ($entry in ($DiskCleanupCatalog | Where-Object { $_.Tier -le $MaxTier })) {
        if ($entry.Tier -ge 2 -and (Get-DiskFreeGB) -ge $DiskWarnFreeGB) { $stoppedBy = 'target reached'; break }
        if ($stopwatch.Elapsed.TotalSeconds -gt $DiskCleanupBudgetSeconds) { $stoppedBy = "time budget hit before '$($entry.Label)'"; break }
        $bytes = 0
        try {
            if ($entry.Action) {
                # No file list to add up, so measure the drive around the call instead.
                $before = (Get-PSDrive -Name C).Free
                & $entry.Action | Out-Null
                $bytes = [math]::Max(0, (Get-PSDrive -Name C).Free - $before)
            } else {
                $bytes = Remove-CleanupTarget -Paths @(& $entry.Paths) -AgeDays ([int]$entry.AgeDays) -RemoveFolder:([bool]$entry.RemoveFolder)
            }
        } catch { }
        $totalBytes += $bytes
        $mb = [math]::Round($bytes / 1MB)
        if ($mb -gt 0) { $freed += "$($entry.Label) $mb MB" }
    }
    $nowGB = Get-DiskFreeGB
    $notes = @()
    if ($freed.Count -gt 0) { $notes += ($freed -join ', ') }
    if ($stoppedBy)         { $notes += $stoppedBy }
    if ($MaxTier -ge 2 -and $nowGB -lt $DiskMinFreeGB) {
        if (Start-WindowsDiskCleanupInBackground) { $notes += 'still below minimum; Windows Disk Cleanup (Update Cleanup) started in the background, re-run to confirm' }
        else                                      { $notes += 'still below minimum and cleanmgr.exe is not available; needs a human' }
    }
    $summary = "freed $([math]::Round($totalBytes / 1MB)) MB, now $nowGB GB free"
    if ($notes.Count -gt 0) { $summary += " ($($notes -join '; '))" }
    return $summary
}

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
        ResolveOnWarning = $true   # Low disk is why the device is unpatched; clean up, do not just note it
        DetectionScript  = {
            try { $freeGB = Get-DiskFreeGB }
            catch { return @{ Status = 'Warning'; Message = 'Unable to query C: drive free space' } }
            if ($freeGB -lt $DiskMinFreeGB) {
                return @{ Status = 'Failed'; Message = "Only $($freeGB)GB free on C: -- updates require at least $($DiskMinFreeGB)GB" }
            }
            if ($freeGB -lt $DiskWarnFreeGB) {
                return @{ Status = 'Warning'; Message = "$($freeGB)GB free on C: -- low, may affect large updates" }
            }
            return @{ Status = 'Passed'; Message = "$($freeGB)GB free on C:" }
        }
        ResolutionScript = {
            # Failed means an update cannot stage at all, so every tier is on the table.
            # Warning means large updates are at risk, so only the free wins run.
            $maxTier = if ((Get-DiskFreeGB) -lt $DiskMinFreeGB) { 2 } else { 1 }
            Invoke-DiskCleanup -MaxTier $maxTier
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

Write-Output "`r`n-- Invoke-AutoRemediateWindowsUpdates ---------------------------"
Write-Output "   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')   Steps: $($activeSteps.Count)"
Write-Output '----------------------------------------------------------------'

foreach ($step in $activeSteps) {

    $status     = 'Failed'
    $message    = 'Detection script did not return a result.'
    $remediated = $false
    $remError   = ''
    $remNote    = ''

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
            # A resolution script may return one line of text to show beside the result,
            # e.g. what step 7 freed. Anything else it emits is discarded as before.
            $remOutput  = @(& $step.ResolutionScript | Where-Object { $_ -is [string] })
            $remNote    = ($remOutput -join '; ')
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
    $remText = if ($remediated -and $remNote) { "  -> Remediation ran: $remNote" }
               elseif ($remediated)          { '  -> Remediation ran' }
               elseif ($remError)            { "  -> Remediation ERROR: $remError" }
               else                          { '' }

    Write-Output "`r`n  [$($status.PadRight(7))] $($step.Name): $message$remText"

    $results.Add([PSCustomObject]@{
        Order      = $step.Order
        Name       = $step.Name
        Status     = $status
        Message    = $message
        Remediated = $remediated
        RemNote    = $remNote
        RemError   = $remError
    })
}

# -- Summary -------------------------------------------------------------------
# @() guards: in Windows PowerShell 5.1 a single PSCustomObject has no .Count, so a
# lone Failed step would otherwise yield $null here and the script would exit 0.
$passed   = @($results | Where-Object { $_.Status -eq 'Passed'  }).Count
$warnings = @($results | Where-Object { $_.Status -eq 'Warning' }).Count
$failed   = @($results | Where-Object { $_.Status -eq 'Failed'  }).Count
$remCount = @($results | Where-Object { $_.Remediated }).Count

Write-Output "`r`n----------------------------------------------------------------"
Write-Output "  Passed: $passed  |  Warnings: $warnings  |  Failed: $failed  |  Remediations run: $remCount"
Write-Output "`r`n----------------------------------------------------------------"

if ($failed -gt 0) { exit 1 }
exit 0
