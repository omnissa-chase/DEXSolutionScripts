#Requires -Version 5.1
<#
.SYNOPSIS
    Trims the per-user cache and temp data that inflates user profile load time at
    logon, and flags the two common causes of slow profile load that cannot be
    safely fixed from the endpoint.

.DESCRIPTION
    User Profile Service load time (the phase measured between User Profile Service
    events 1 and 2) scales with the number of files in the profile and the size of the
    user registry hive. On roaming, FSLogix, or UPD profiles this is the difference
    between a two second logon and a two minute one, because that data is copied or
    attached before the shell is released.

    This script targets caches only -- data Windows and applications regenerate on
    demand. It never touches Documents, Desktop, Downloads, saved credentials,
    bookmarks, browser history, Outlook data files, or signatures.

    +------+-------------------------------------+----------------------------------+
    | Step | Name                                | Action                           |
    +------+-------------------------------------+----------------------------------+
    |  1   | User Temp Files                     | Delete aged files                |
    |  2   | Browser Caches                      | Delete aged files                |
    |  3   | Teams Cache                         | Delete aged files                |
    |  4   | Explorer Thumbnail and Icon Cache   | Delete aged files                |
    |  5   | Crash Dumps and Error Reports       | Delete aged files                |
    |  6   | RDP and Shader Caches               | Delete aged files                |
    |  7   | Recent Items and Jump Lists         | Delete aged files                |
    |  8   | Oversized Roaming AppData           | Report only                      |
    |  9   | Oversized User Registry Hive        | Report only                      |
    +------+-------------------------------------+----------------------------------+

    Steps 8 and 9 deliberately have no remediation. An oversized roaming AppData is
    usually one misbehaving application writing state where it should not, and an
    oversized NTUSER.DAT needs a hive rebuild -- both need a human to look at them,
    and neither is safe to guess at. They report so the runbook knows to escalate
    when steps 1-7 clean up but logons stay slow.

    All non-special profiles on the device are processed. Files locked by a live
    session are skipped rather than forced.

    Results are written to HKLM:\Software\AirWatch\Extensions\ProfileBloat\Remediation.

.PARAMETER MinFileAgeDays
    Only files last written more than this many days ago are eligible for deletion,
    so an active session's working cache is left intact. Defaults to $env:MinFileAgeDays,
    then to 7.

.PARAMETER MinSizeThresholdMB
    A cleanup step only reports Failed, and therefore only remediates, once its target
    exceeds this size. Keeps the script from churning the disk to reclaim a few MB.
    Defaults to $env:MinSizeThresholdMB, then to 50.

.PARAMETER RoamingWarnMB
    Roaming AppData size that triggers the report-only warning in step 8.
    Defaults to $env:RoamingWarnMB, then to 500.

.PARAMETER HiveWarnMB
    User registry hive size that triggers the report-only warning in step 9.
    Defaults to $env:HiveWarnMB, then to 100.

.EXAMPLE
    .\Invoke-AutoRemediateProfileBloat.ps1 -MinFileAgeDays 14 -MinSizeThresholdMB 250

    Only deletes cache files older than two weeks, and only from targets holding at
    least 250 MB.

.EXAMPLE
    $env:WhatIf = 'true'; .\Invoke-AutoRemediateProfileBloat.ps1

    Reports what each step would reclaim without deleting anything. This is the
    intended first run in a new environment.

.NOTES
    Script Name  : Invoke-AutoRemediateProfileBloat.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-05
    Timeout      : 300 seconds

    Environment variables:
      WhatIf             = true   Dry run. Absent/unparseable => live run.
      MinFileAgeDays     = 7
      MinSizeThresholdMB = 50
      RoamingWarnMB      = 500
      HiveWarnMB         = 100

    Explicit parameters win over environment variables.

    Related, non-overlapping scripts:
      DiskCleanup\Start-UserProfileCleanup.ps1  Deletes entire inactive profiles.
      DiskCleanup\Start-DiskCleanup.ps1         cleanmgr, system-level categories.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    # ValidateRange applies to explicit arguments only, so a bad environment variable
    # degrades to the default instead of failing the run.
    [ValidateRange(0, 365)]
    [int]$MinFileAgeDays = $(
        $v = 0
        if ([int]::TryParse("$env:MinFileAgeDays".Trim(), [ref]$v) -and $v -ge 0) { $v } else { 7 }
    ),

    [ValidateRange(0, 1048576)]
    [int]$MinSizeThresholdMB = $(
        $v = 0
        if ([int]::TryParse("$env:MinSizeThresholdMB".Trim(), [ref]$v) -and $v -ge 0) { $v } else { 50 }
    ),

    [ValidateRange(1, 1048576)]
    [int]$RoamingWarnMB = $(
        $v = 0
        if ([int]::TryParse("$env:RoamingWarnMB".Trim(), [ref]$v) -and $v -gt 0) { $v } else { 500 }
    ),

    [ValidateRange(1, 1048576)]
    [int]$HiveWarnMB = $(
        $v = 0
        if ([int]::TryParse("$env:HiveWarnMB".Trim(), [ref]$v) -and $v -gt 0) { $v } else { 100 }
    )
)

$SCRIPT_VERSION = "1.0.0"
$RegPath        = "HKLM:\Software\AirWatch\Extensions\ProfileBloat\Remediation"
$LogPath        = "$env:SystemRoot\Temp\UEM_AutoRemediateProfileBloat.log"

# -- WhatIf bridge -------------------------------------------------------------
# UEM cannot set $WhatIfPreference directly. Bridge it from an environment
# variable. Absent, empty, or unparseable => $false (live run).
$WhatIfPreference = $false
if ($env:WhatIf) {
    try   { $WhatIfPreference = [System.Convert]::ToBoolean($env:WhatIf) }
    catch { $WhatIfPreference = $false }
}

# -- Run header ----------------------------------------------------------------
$RunEventId = ([Random]::new()).Next(1000, 9999)
Write-Host "[$RunEventId] Executing Invoke-AutoRemediateProfileBloat, $SCRIPT_VERSION. Started @ '$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))'  WhatIf=$WhatIfPreference"
$HEAD = "`r`n[$RunEventId]"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    # -WhatIf:$false so a dry run is still recorded; the log is evidence, not state.
    "[$timestamp] [$RunEventId] [$Level] $Message" |
        Out-File -FilePath $LogPath -Append -Encoding UTF8 -WhatIf:$false -ErrorAction SilentlyContinue
}

Write-Log "Settings: MinFileAgeDays=$MinFileAgeDays MinSizeThresholdMB=$MinSizeThresholdMB RoamingWarnMB=$RoamingWarnMB HiveWarnMB=$HiveWarnMB"

# -- Profiles in scope ----------------------------------------------------------
$UserProfiles = @(
    Get-CimInstance -ClassName Win32_UserProfile -ErrorAction SilentlyContinue |
        Where-Object { -not $_.Special -and $_.LocalPath -and (Test-Path -LiteralPath $_.LocalPath) }
)

if ($UserProfiles.Count -eq 0) {
    Write-Host "$HEAD No non-special user profiles found on this device. Nothing to do." -ForegroundColor Yellow
    Write-Log 'No user profiles in scope. Exiting without changes.'
    exit 0
}

Write-Host "$HEAD Profiles in scope: $($UserProfiles.Count) ($(($UserProfiles | ForEach-Object { Split-Path $_.LocalPath -Leaf }) -join ', '))"
Write-Log "Profiles in scope: $(($UserProfiles.LocalPath) -join ', ')"

$script:TotalBytesReclaimed = 0

# -- Helpers --------------------------------------------------------------------
function Get-ProfilePaths {
    param([string[]]$RelativePaths)
    $out = @()
    foreach ($userProfile in $UserProfiles) {
        foreach ($rel in $RelativePaths) {
            $out += (Join-Path $userProfile.LocalPath $rel)
        }
    }
    return $out
}

function Expand-TargetPath {
    param([string[]]$Paths)
    # Wildcards must be resolved before recursing: Get-ChildItem -Path 'a\*\Cache'
    # -Recurse treats the trailing segment as a filename filter, so a mid-path
    # wildcard silently matches nothing.
    $items = @()
    foreach ($path in $Paths) {
        $resolved = Resolve-Path -Path $path -ErrorAction SilentlyContinue
        foreach ($entry in $resolved) { $items += $entry.ProviderPath }
    }
    return $items
}

function Measure-CacheTarget {
    param([string[]]$Paths, [int]$AgeDays)
    $cutoff = (Get-Date).AddDays(-$AgeDays)
    $bytes  = 0
    $count  = 0
    foreach ($item in (Expand-TargetPath -Paths $Paths)) {
        Get-ChildItem -LiteralPath $item -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoff } |
            ForEach-Object { $bytes += $_.Length; $count++ }
    }
    return [PSCustomObject]@{
        Bytes     = $bytes
        MB        = [math]::Round($bytes / 1MB, 1)
        FileCount = $count
    }
}

function Remove-CacheTarget {
    param([string[]]$Paths, [int]$AgeDays)
    $cutoff  = (Get-Date).AddDays(-$AgeDays)
    $bytes   = 0
    $removed = 0
    $locked  = 0
    foreach ($item in (Expand-TargetPath -Paths $Paths)) {
        Get-ChildItem -LiteralPath $item -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoff } |
            ForEach-Object {
                $size = $_.Length
                try {
                    Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop
                    $bytes   += $size
                    $removed += 1
                } catch {
                    # In use by a live session. Leave it; it is a cache, it will age out.
                    $locked += 1
                }
            }
    }
    $script:TotalBytesReclaimed += $bytes
    Write-Log "Reclaimed $([math]::Round($bytes / 1MB, 1)) MB from $removed file(s); $locked file(s) locked and skipped."
}

# -- Cache targets --------------------------------------------------------------
# Only regenerable data. Nothing here holds user documents, credentials, bookmarks,
# history, or mail.
$TempPaths = Get-ProfilePaths @(
    'AppData\Local\Temp'
)

$BrowserPaths = Get-ProfilePaths @(
    'AppData\Local\Google\Chrome\User Data\*\Cache'
    'AppData\Local\Google\Chrome\User Data\*\Code Cache'
    'AppData\Local\Google\Chrome\User Data\*\GPUCache'
    'AppData\Local\Google\Chrome\User Data\*\Service Worker\CacheStorage'
    'AppData\Local\Microsoft\Edge\User Data\*\Cache'
    'AppData\Local\Microsoft\Edge\User Data\*\Code Cache'
    'AppData\Local\Microsoft\Edge\User Data\*\GPUCache'
    'AppData\Local\Microsoft\Edge\User Data\*\Service Worker\CacheStorage'
    'AppData\Local\Mozilla\Firefox\Profiles\*\cache2'
    'AppData\Local\Microsoft\Windows\INetCache'
)

$TeamsPaths = Get-ProfilePaths @(
    'AppData\Roaming\Microsoft\Teams\Cache'
    'AppData\Roaming\Microsoft\Teams\Code Cache'
    'AppData\Roaming\Microsoft\Teams\GPUCache'
    'AppData\Roaming\Microsoft\Teams\blob_storage'
    'AppData\Roaming\Microsoft\Teams\tmp'
    'AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\*\Cache'
    'AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\*\Code Cache'
    'AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\*\GPUCache'
)

$ExplorerCachePaths = Get-ProfilePaths @(
    'AppData\Local\Microsoft\Windows\Explorer\thumbcache_*.db'
    'AppData\Local\Microsoft\Windows\Explorer\iconcache_*.db'
)

$CrashDumpPaths = Get-ProfilePaths @(
    'AppData\Local\CrashDumps'
    'AppData\Local\Microsoft\Windows\WER\ReportArchive'
    'AppData\Local\Microsoft\Windows\WER\ReportQueue'
)

$ShaderCachePaths = Get-ProfilePaths @(
    'AppData\Local\Microsoft\Terminal Server Client\Cache'
    'AppData\Local\D3DSCache'
    'AppData\Local\NVIDIA\DXCache'
    'AppData\Local\NVIDIA\GLCache'
    'AppData\Local\AMD\DxCache'
)

# Roaming, so these are copied at every logon on a roaming profile.
$RecentItemPaths = Get-ProfilePaths @(
    'AppData\Roaming\Microsoft\Windows\Recent\*.lnk'
    'AppData\Roaming\Microsoft\Windows\Recent\AutomaticDestinations'
    'AppData\Roaming\Microsoft\Windows\Recent\CustomDestinations'
)

# -- Step Definitions -----------------------------------------------------------
# Only supported fields: Name, Order, Enabled, ResolveOnWarning,
#                        DetectionScript, ResolutionScript
$Steps = @(

    @{
        Name             = 'User Temp Files'
        Order            = 1
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            $m = Measure-CacheTarget -Paths $TempPaths -AgeDays $MinFileAgeDays
            if ($m.MB -ge $MinSizeThresholdMB) {
                return @{ Status = 'Failed'; Message = "$($m.MB) MB in $($m.FileCount) file(s) older than $MinFileAgeDays day(s)" }
            }
            return @{ Status = 'Passed'; Message = "$($m.MB) MB, below the $MinSizeThresholdMB MB threshold" }
        }
        ResolutionScript = { Remove-CacheTarget -Paths $TempPaths -AgeDays $MinFileAgeDays }
    },

    @{
        Name             = 'Browser Caches'
        Order            = 2
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            $m = Measure-CacheTarget -Paths $BrowserPaths -AgeDays $MinFileAgeDays
            if ($m.MB -ge $MinSizeThresholdMB) {
                return @{ Status = 'Failed'; Message = "$($m.MB) MB in $($m.FileCount) file(s) older than $MinFileAgeDays day(s)" }
            }
            return @{ Status = 'Passed'; Message = "$($m.MB) MB, below the $MinSizeThresholdMB MB threshold" }
        }
        ResolutionScript = { Remove-CacheTarget -Paths $BrowserPaths -AgeDays $MinFileAgeDays }
    },

    @{
        Name             = 'Teams Cache'
        Order            = 3
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            $m = Measure-CacheTarget -Paths $TeamsPaths -AgeDays $MinFileAgeDays
            if ($m.MB -ge $MinSizeThresholdMB) {
                return @{ Status = 'Failed'; Message = "$($m.MB) MB in $($m.FileCount) file(s) older than $MinFileAgeDays day(s)" }
            }
            return @{ Status = 'Passed'; Message = "$($m.MB) MB, below the $MinSizeThresholdMB MB threshold" }
        }
        ResolutionScript = { Remove-CacheTarget -Paths $TeamsPaths -AgeDays $MinFileAgeDays }
    },

    @{
        Name             = 'Explorer Thumbnail and Icon Cache'
        Order            = 4
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            $m = Measure-CacheTarget -Paths $ExplorerCachePaths -AgeDays $MinFileAgeDays
            if ($m.MB -ge $MinSizeThresholdMB) {
                return @{ Status = 'Failed'; Message = "$($m.MB) MB in $($m.FileCount) cache database(s)" }
            }
            return @{ Status = 'Passed'; Message = "$($m.MB) MB, below the $MinSizeThresholdMB MB threshold" }
        }
        ResolutionScript = { Remove-CacheTarget -Paths $ExplorerCachePaths -AgeDays $MinFileAgeDays }
    },

    @{
        Name             = 'Crash Dumps and Error Reports'
        Order            = 5
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            $m = Measure-CacheTarget -Paths $CrashDumpPaths -AgeDays $MinFileAgeDays
            if ($m.MB -ge $MinSizeThresholdMB) {
                return @{ Status = 'Failed'; Message = "$($m.MB) MB in $($m.FileCount) file(s) older than $MinFileAgeDays day(s)" }
            }
            return @{ Status = 'Passed'; Message = "$($m.MB) MB, below the $MinSizeThresholdMB MB threshold" }
        }
        ResolutionScript = { Remove-CacheTarget -Paths $CrashDumpPaths -AgeDays $MinFileAgeDays }
    },

    @{
        Name             = 'RDP and Shader Caches'
        Order            = 6
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            $m = Measure-CacheTarget -Paths $ShaderCachePaths -AgeDays $MinFileAgeDays
            if ($m.MB -ge $MinSizeThresholdMB) {
                return @{ Status = 'Failed'; Message = "$($m.MB) MB in $($m.FileCount) file(s) older than $MinFileAgeDays day(s)" }
            }
            return @{ Status = 'Passed'; Message = "$($m.MB) MB, below the $MinSizeThresholdMB MB threshold" }
        }
        ResolutionScript = { Remove-CacheTarget -Paths $ShaderCachePaths -AgeDays $MinFileAgeDays }
    },

    @{
        Name             = 'Recent Items and Jump Lists'
        Order            = 7
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            $m = Measure-CacheTarget -Paths $RecentItemPaths -AgeDays $MinFileAgeDays
            # File count matters more than size here -- these are thousands of tiny
            # roaming files, and it is the count that slows the profile copy.
            if ($m.FileCount -ge 500 -or $m.MB -ge $MinSizeThresholdMB) {
                return @{ Status = 'Failed'; Message = "$($m.FileCount) file(s) totalling $($m.MB) MB older than $MinFileAgeDays day(s)" }
            }
            return @{ Status = 'Passed'; Message = "$($m.FileCount) file(s), $($m.MB) MB -- not a contributor" }
        }
        ResolutionScript = { Remove-CacheTarget -Paths $RecentItemPaths -AgeDays $MinFileAgeDays }
    },

    @{
        # Report only. Oversized roaming data is an application misbehaving, and
        # deciding what may be deleted from it is not a call this script can make.
        Name             = 'Oversized Roaming AppData'
        Order            = 8
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            $oversized = @()
            foreach ($userProfile in $UserProfiles) {
                $roaming = Join-Path $userProfile.LocalPath 'AppData\Roaming'
                $m = Measure-CacheTarget -Paths @($roaming) -AgeDays 0
                if ($m.MB -ge $RoamingWarnMB) {
                    $oversized += "$(Split-Path $userProfile.LocalPath -Leaf) ($($m.MB) MB)"
                }
            }
            if ($oversized) {
                return @{ Status = 'Warning'; Message = "Roaming AppData over $RoamingWarnMB MB: $($oversized -join ', '). Investigate which application is writing there; not auto-remediated." }
            }
            return @{ Status = 'Passed'; Message = "All roaming profiles under $RoamingWarnMB MB" }
        }
        ResolutionScript = $null
    },

    @{
        # Report only. A bloated hive needs a rebuild, which is a logged-off,
        # backed-up, human-supervised operation.
        Name             = 'Oversized User Registry Hive'
        Order            = 9
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            $oversized = @()
            foreach ($userProfile in $UserProfiles) {
                $hives = @(
                    (Join-Path $userProfile.LocalPath 'NTUSER.DAT')
                    (Join-Path $userProfile.LocalPath 'AppData\Local\Microsoft\Windows\UsrClass.dat')
                )
                foreach ($hive in $hives) {
                    $file = Get-Item -LiteralPath $hive -Force -ErrorAction SilentlyContinue
                    if ($file -and ($file.Length / 1MB) -ge $HiveWarnMB) {
                        $oversized += "$(Split-Path $userProfile.LocalPath -Leaf)\$($file.Name) ($([math]::Round($file.Length / 1MB, 1)) MB)"
                    }
                }
            }
            if ($oversized) {
                return @{ Status = 'Warning'; Message = "Registry hive over $HiveWarnMB MB: $($oversized -join ', '). Needs a supervised hive rebuild; not auto-remediated." }
            }
            return @{ Status = 'Passed'; Message = "All user registry hives under $HiveWarnMB MB" }
        }
        ResolutionScript = $null
    }
)

# -- Execution Engine ------------------------------------------------------------
$activeSteps = $Steps |
    Where-Object { $_.Enabled } |
    Sort-Object   { [int]$_.Order }

$results = New-Object 'System.Collections.Generic.List[PSCustomObject]'

Write-Host "`n-- Invoke-AutoRemediateProfileBloat --------------------------------" -ForegroundColor Cyan
Write-Host "   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')   Steps: $($activeSteps.Count)"
Write-Host '--------------------------------------------------------------------' -ForegroundColor Cyan

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

    # -- Remediation ------------------------------------------------------------
    $shouldRemediate = ($status -eq 'Failed') -or
                       ($status -eq 'Warning' -and $step.ResolveOnWarning)

    if ($shouldRemediate -and $step.ResolutionScript) {
        if ($PSCmdlet.ShouldProcess($step.Name, 'Delete aged cache files')) {
            try {
                & $step.ResolutionScript | Out-Null
                $remediated = $true
            } catch {
                $remError = $_.Exception.Message
            }
        }
    }

    # -- Output -------------------------------------------------------------------
    $color = switch ($status) {
        'Passed'  { 'Green'  }
        'Warning' { 'Yellow' }
        'Failed'  { 'Red'    }
        default   { 'White'  }
    }
    $remNote = if ($remediated)   { '  -> Cleanup applied' }
               elseif ($remError) { "  -> Cleanup ERROR: $remError" }
               else               { '' }

    Write-Host "`n  [$($status.PadRight(7))] $($step.Name): $message$remNote" -ForegroundColor $color
    Write-Log "$($step.Name): $status - $message$remNote"

    $results.Add([PSCustomObject]@{
        Order      = $step.Order
        Name       = $step.Name
        Status     = $status
        Message    = $message
        Remediated = $remediated
        RemError   = $remError
    })
}

# -- Summary -----------------------------------------------------------------
$passed      = ($results | Where-Object { $_.Status -eq 'Passed'  }).Count
$warnings    = ($results | Where-Object { $_.Status -eq 'Warning' }).Count
$failed      = ($results | Where-Object { $_.Status -eq 'Failed'  }).Count
$remCount    = ($results | Where-Object { $_.Remediated }).Count
$remErrs     = ($results | Where-Object { $_.RemError }).Count
$reclaimedMB = [math]::Round($script:TotalBytesReclaimed / 1MB, 1)

Write-Host "`n--------------------------------------------------------------------" -ForegroundColor Cyan
Write-Host "  Passed: $passed  |  Warnings: $warnings  |  Failed: $failed  |  Cleanups applied: $remCount"
Write-Host "  Reclaimed: $reclaimedMB MB"
Write-Host "--------------------------------------------------------------------`n" -ForegroundColor Cyan
Write-Log "Summary: Passed=$passed Warnings=$warnings Failed=$failed CleanupsApplied=$remCount CleanupErrors=$remErrs ReclaimedMB=$reclaimedMB"

# -- Registry Reporting --------------------------------------------------------
# Skipped entirely on a WhatIf run -- a dry run must not claim a remediation state
# that was never actually applied.
if (-not $WhatIfPreference) {
    try {
        if (-not (Test-Path $RegPath)) {
            New-Item -Path $RegPath -Force -ErrorAction Stop | Out-Null
        }
        Set-ItemProperty -Path $RegPath -Name 'LastRun'           -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') -Type String
        Set-ItemProperty -Path $RegPath -Name 'ScriptVersion'     -Value $SCRIPT_VERSION -Type String
        Set-ItemProperty -Path $RegPath -Name 'Passed'            -Value $passed   -Type DWord
        Set-ItemProperty -Path $RegPath -Name 'Warnings'          -Value $warnings -Type DWord
        Set-ItemProperty -Path $RegPath -Name 'Failed'            -Value $failed   -Type DWord
        Set-ItemProperty -Path $RegPath -Name 'CleanupsRun'       -Value $remCount -Type DWord
        Set-ItemProperty -Path $RegPath -Name 'CleanupErrors'     -Value $remErrs  -Type DWord
        Set-ItemProperty -Path $RegPath -Name 'ReclaimedMB'       -Value ([int]$reclaimedMB) -Type DWord
        Set-ItemProperty -Path $RegPath -Name 'ProfilesProcessed' -Value $UserProfiles.Count -Type DWord
        Write-Log "Results cached to $RegPath"
    } catch {
        Write-Log "Registry cache write failed: $($_.Exception.Message)" 'WARN'
    }
} else {
    Write-Log 'WhatIf run -- registry cache left untouched.'
}

exit $(if ($remErrs -gt 0) { 1 } else { 0 })
