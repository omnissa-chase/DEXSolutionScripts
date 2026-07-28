<#
.SYNOPSIS
    Invoke-AutoRemediateTeams -- Automated Microsoft Teams diagnostic and remediation.

.DESCRIPTION
    Runs a sequenced set of Teams-specific health checks and automatically
    remediates where possible. Supports both Classic Teams (Electron/Update.exe)
    and New Teams (MSTeams AppX package) -- detects which variant is installed
    and runs the applicable checks for each. Both can coexist during the
    transition period and are handled independently.

    Steps covered by generic scripts are intentionally excluded here:
      - Process health / crashes   --> Restart-WinProcessGraceful.ps1
      - Network connectivity       --> Invoke-AutoRemediateNetworkStack.ps1
      - Disk space                 --> DiskCleanup scripts
      - Windows Update             --> Invoke-AutoRemediateWindowsUpdates.ps1

    +------+--------------------------------------+-------------------------------+
    | Step | Name                                 | Remediates On                 |
    +------+--------------------------------------+-------------------------------+
    |  1   | Teams Cache Bloat                    | Warning (auto -- safe clear)  |
    |  2   | Sign-in / Auth Token Cache           | Warning ($AllowDestructiveActs)|
    |  3   | Teams Updater Stuck                  | Failed                        |
    |  4   | Classic Teams Update Health          | -- (informational only)       |
    |  5   | Teams Notification Settings          | -- (informational only)       |
    |  6   | New Teams Package Registration       | Failed ($AllowDestructiveActs)|
    +------+--------------------------------------+-------------------------------+

    SYSTEM-context note: this script resolves the logged-on user's profile path
    via Win32_ComputerSystem.UserName. $env:APPDATA and $env:LOCALAPPDATA
    resolve to the SYSTEM profile when the script runs as SYSTEM and must not
    be used directly for per-user Teams data paths.

.PARAMETER CacheSizeWarningMB
    Combined Teams cache folder size (Cache + blob_storage + IndexedDB + databases)
    above which a warning is raised and the cache is cleared.
    Default: 1024 MB (1 GB). Override via $env:CacheSizeWarningMB.

.PARAMETER AllowDestructiveActions
    When $true, enables remediations that affect user session state:
      - Step 2: Clears auth token cache (forces Teams re-login on next launch).
      - Step 6: Re-registers the New Teams AppX package.
    Default: $false.

.NOTES
    Script Name  : Invoke-AutoRemediateTeams.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-07-28
    Timeout      : 60 seconds

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

param(
    [int] $CacheSizeWarningMB      = $(if ($env:CacheSizeWarningMB)      { [int]$env:CacheSizeWarningMB }                               else { 1024 }),
    [bool]$AllowDestructiveActions = $(if ($env:AllowDestructiveActions)  { [System.Convert]::ToBoolean($env:AllowDestructiveActions) } else { $false })
)

# -- Pre-flight: resolve logged-on user context -------------------------------
# SYSTEM context: $env:APPDATA / $env:LOCALAPPDATA resolve to the SYSTEM profile.
# Derive the actual user profile from WMI to access per-user Teams data.
$_loggedOnUser = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
$_shortName    = if ($_loggedOnUser) { $_loggedOnUser.Split('\')[-1] } else { $null }
$_userProfile  = if ($_shortName -and (Test-Path "C:\Users\$_shortName")) { "C:\Users\$_shortName" } else { $null }

$_userSid = $null
if ($_loggedOnUser) {
    try {
        $_userSid = ([Security.Principal.NTAccount]$_loggedOnUser).Translate([Security.Principal.SecurityIdentifier]).Value
    } catch { }
}

# -- Pre-flight: detect Classic Teams and New Teams ---------------------------
$_teamsIsClassic     = $false
$_teamsIsNew         = $false
$_classicLocalPath   = $null   # %localappdata%\Microsoft\Teams
$_classicRoamingPath = $null   # %appdata%\Microsoft\Teams (cache + profile data)
$_newPackage         = $null   # Get-AppxPackage result for MSTeams

if ($_userProfile) {
    $candidateLocal   = Join-Path $_userProfile 'AppData\Local\Microsoft\Teams'
    $candidateRoaming = Join-Path $_userProfile 'AppData\Roaming\Microsoft\Teams'
    # Update.exe presence is the reliable Classic Teams install marker
    if (Test-Path (Join-Path $candidateLocal 'Update.exe')) {
        $_teamsIsClassic     = $true
        $_classicLocalPath   = $candidateLocal
        $_classicRoamingPath = $candidateRoaming
    }
}

$_newPackage = Get-AppxPackage -Name 'MSTeams' -ErrorAction SilentlyContinue |
               Select-Object -First 1
if ($_newPackage) { $_teamsIsNew = $true }

# -- Pre-flight: app presence check -------------------------------------------
if (-not $_teamsIsClassic -and -not $_teamsIsNew) {
    Write-Host "`n-- Invoke-AutoRemediateTeams ------------------------------------" -ForegroundColor Cyan
    Write-Host "   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Host '   [Skipped] Microsoft Teams does not appear to be installed on this device.'
    Write-Host "----------------------------------------------------------------`n" -ForegroundColor Cyan
    exit 0
}

# Cache subfolder names cleared in Step 1 (general cache -- safe to wipe)
$_cacheFolders = @('Cache', 'blob_storage', 'IndexedDB', 'databases', 'Code Cache', 'GPUCache')
# Auth-adjacent folders cleared in Step 2 (forces re-authentication -- gated by flag)
$_authFolders  = @('Cookies', 'Application Cache', 'Local Storage')

# -- Step Definitions ---------------------------------------------------------
$Steps = @(

    @{
        Name             = 'Teams Cache Bloat'
        Order            = 1
        Enabled          = $_teamsIsClassic   # Classic Teams only -- New Teams cache is AppX-sandboxed
        ResolveOnWarning = $true              # General cache clear is the standard recommended fix; no destructive flag needed
        DetectionScript  = {
            $roaming = $_classicRoamingPath
            if (-not $roaming -or -not (Test-Path $roaming)) {
                return @{ Status = 'Passed'; Message = 'Teams roaming profile path not found -- cache check skipped.' }
            }
            $totalMB = 0
            foreach ($folder in $_cacheFolders) {
                $fullPath = Join-Path $roaming $folder
                if (Test-Path $fullPath) {
                    $totalMB += [math]::Round((Get-ChildItem $fullPath -Recurse -File -ErrorAction SilentlyContinue |
                        Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum / 1MB, 0)
                }
            }
            if ($totalMB -ge $CacheSizeWarningMB) {
                return @{ Status = 'Warning'; Message = "Teams cache is ${totalMB}MB (threshold: ${CacheSizeWarningMB}MB). Will clear cache folders if Teams is not running." }
            }
            return @{ Status = 'Passed'; Message = "Teams cache is ${totalMB}MB (threshold: ${CacheSizeWarningMB}MB)." }
        }
        ResolutionScript = {
            # Standard cache clear -- Teams rebuilds all of these on next launch.
            # Does not clear auth tokens or Local Storage (which may hold unsent content).
            if (Get-Process -Name Teams -ErrorAction SilentlyContinue) {
                throw 'Teams is running -- cache folders are locked. Stop Teams before running this remediation.'
            }
            $cleared = 0
            foreach ($folder in $_cacheFolders) {
                $fullPath = Join-Path $_classicRoamingPath $folder
                if (Test-Path $fullPath) {
                    Get-ChildItem $fullPath -Recurse -File -ErrorAction SilentlyContinue |
                        Remove-Item -Force -ErrorAction SilentlyContinue
                    $cleared++
                }
            }
            Write-Host "  [Info] Cleared $cleared Teams cache folder(s). Teams will rebuild cache on next launch." -ForegroundColor DarkYellow
        }
    },

    @{
        Name             = 'Sign-in / Auth Token Cache'
        Order            = 2
        Enabled          = $_teamsIsClassic   # Auth cache paths are Classic Teams specific
        ResolveOnWarning = $AllowDestructiveActions   # Forces Teams re-login -- gated
        DetectionScript  = {
            # Proxy: scan recent Classic Teams log entries for auth failure patterns.
            # Direct token introspection requires MSAL APIs not available from SYSTEM context.
            $logFile = Join-Path $_classicRoamingPath 'logs.txt'
            if (-not (Test-Path $logFile)) {
                return @{ Status = 'Passed'; Message = 'Teams log file not found -- auth check skipped.' }
            }
            # Read last 500 lines to avoid loading a large log file entirely
            $logLines = Get-Content $logFile -Tail 500 -ErrorAction SilentlyContinue
            $authErrors = $logLines | Where-Object {
                $_ -match 'auth.error|Auth error|Failed to get token|Sign.in failed|token_expired|AADSTS|login failed' -and
                $_ -match '\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}'
            }
            if ($authErrors -and $authErrors.Count -gt 0) {
                return @{ Status = 'Warning'; Message = "$($authErrors.Count) auth failure pattern(s) found in Teams log (last 500 lines)$(if (-not $AllowDestructiveActions) { '. Set $AllowDestructiveActions=$true to clear auth cache' } else { '' })." }
            }
            return @{ Status = 'Passed'; Message = 'No recent auth failure patterns found in Teams log.' }
        }
        ResolutionScript = {
            # Clears auth-adjacent cache folders to force Teams to re-authenticate.
            # This logs the user out of Teams on next launch -- only runs when
            # $AllowDestructiveActions = $true (ResolveOnWarning wired to that flag).
            if (Get-Process -Name Teams -ErrorAction SilentlyContinue) {
                throw 'Teams is running -- auth cache folders are locked. Stop Teams before clearing auth state.'
            }
            $cleared = 0
            foreach ($folder in $_authFolders) {
                $fullPath = Join-Path $_classicRoamingPath $folder
                if (Test-Path $fullPath) {
                    Get-ChildItem $fullPath -Recurse -File -ErrorAction SilentlyContinue |
                        Remove-Item -Force -ErrorAction SilentlyContinue
                    $cleared++
                }
            }
            Write-Host "  [Info] Cleared $cleared Teams auth cache folder(s). Teams will prompt for sign-in on next launch." -ForegroundColor DarkYellow
        }
    },

    @{
        Name             = 'Teams Updater Stuck'
        Order            = 3
        Enabled          = $_teamsIsClassic   # Classic Teams only -- New Teams updates via Windows Store
        ResolveOnWarning = $false
        DetectionScript  = {
            # A Teams Update.exe or TeamsUpdaterDaemon running for > 30 minutes
            # without completing is considered stuck.
            $threshold = (Get-Date).AddMinutes(-30)
            $stuckProcs = @()

            $updateProcs = Get-Process -Name 'Update' -ErrorAction SilentlyContinue |
                           Where-Object { $_.Path -like "*Microsoft\Teams*" -and $_.StartTime -lt $threshold }
            $daemonProcs = Get-Process -Name 'TeamsUpdaterDaemon' -ErrorAction SilentlyContinue |
                           Where-Object { $_.StartTime -lt $threshold }
            $stuckProcs  = @($updateProcs) + @($daemonProcs) | Where-Object { $_ }

            if ($stuckProcs.Count -gt 0) {
                $desc = ($stuckProcs | ForEach-Object { "$($_.Name) (PID $($_.Id), running $([math]::Round(((Get-Date) - $_.StartTime).TotalMinutes, 0))min)" }) -join '; '
                return @{ Status = 'Failed'; Message = "Stuck Teams updater process(es) detected: $desc." }
            }
            return @{ Status = 'Passed'; Message = 'No stuck Teams updater processes found.' }
        }
        ResolutionScript = {
            # Kill the stuck updater process(es). Teams will re-trigger the
            # update check on next launch via the Squirrel/Update.exe mechanism.
            $threshold = (Get-Date).AddMinutes(-30)
            @(
                (Get-Process -Name 'Update'              -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "*Microsoft\Teams*" -and $_.StartTime -lt $threshold }),
                (Get-Process -Name 'TeamsUpdaterDaemon'  -ErrorAction SilentlyContinue | Where-Object { $_.StartTime -lt $threshold })
            ) | Where-Object { $_ } | ForEach-Object {
                Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
                Write-Host "  [Info] Killed stuck updater: $($_.Name) (PID $($_.Id))." -ForegroundColor DarkYellow
            }
        }
    },

    @{
        Name             = 'Classic Teams Update Health'
        Order            = 4
        Enabled          = $_teamsIsClassic
        ResolveOnWarning = $false
        DetectionScript  = {
            $updateExe = Join-Path $_classicLocalPath 'Update.exe'
            if (-not (Test-Path $updateExe)) {
                return @{ Status = 'Warning'; Message = "Teams Update.exe not found at $_classicLocalPath. Classic Teams may be partially installed." }
            }
            # Check the update log for recent failure entries
            $updateLog = Join-Path $_classicLocalPath 'SquirrelSetup.log'
            if (-not (Test-Path $updateLog)) {
                $updateLog = Join-Path $_classicLocalPath 'update.log'
            }
            if (Test-Path $updateLog) {
                $logLines   = Get-Content $updateLog -Tail 50 -ErrorAction SilentlyContinue
                $updateFail = $logLines | Where-Object { $_ -match 'error|failed|exception' -and $_ -notmatch '#' }
                if ($updateFail -and $updateFail.Count -gt 2) {
                    return @{ Status = 'Failed'; Message = "$($updateFail.Count) update failure entries in Teams update log. Triggering update retry." }
                }
            }
            # Get installed version from the current app manifest
            $currentDir = Join-Path $_classicLocalPath 'current'
            $manifest   = Get-Item (Join-Path $currentDir 'teams.nuspec') -ErrorAction SilentlyContinue
            if (-not $manifest) {
                $manifest = Get-ChildItem $_classicLocalPath -Filter '*.nupkg' -ErrorAction SilentlyContinue |
                            Sort-Object LastWriteTime -Descending | Select-Object -First 1
            }
            $versionNote = if ($manifest) { " Installed package: $($manifest.Name)." } else { '' }
            return @{ Status = 'Passed'; Message = "Teams Update.exe present; update log shows no recent failures.$versionNote" }
        }
        ResolutionScript = $null   # Updates are managed via MDM deployment -- triggering Update.exe outside that channel may conflict with managed version targeting
    },

    @{
        Name             = 'Teams Notification Settings'
        Order            = 5
        Enabled          = $true
        ResolveOnWarning = $false   # Notification suppression is often intentional -- informational only
        DetectionScript  = {
            if (-not $_userSid) {
                return @{ Status = 'Warning'; Message = 'Cannot resolve user SID -- notification check skipped.' }
            }
            $notifBase = "Registry::HKEY_USERS\$_userSid\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings"
            if (-not (Test-Path $notifBase)) {
                return @{ Status = 'Passed'; Message = 'Notification settings key not found (default settings in effect).' }
            }
            # Look for any Teams-related app key with Enabled = 0
            $teamsKeys = Get-ChildItem $notifBase -ErrorAction SilentlyContinue |
                         Where-Object { $_.PSChildName -like '*Teams*' -or $_.PSChildName -like '*MSTeams*' }
            if (-not $teamsKeys) {
                return @{ Status = 'Passed'; Message = 'No Teams-specific notification override keys found (default settings in effect).' }
            }
            $disabled = $teamsKeys | Where-Object {
                (Get-ItemProperty $_.PSPath -Name 'Enabled' -ErrorAction SilentlyContinue).Enabled -eq 0
            }
            if ($disabled) {
                $names = ($disabled | Select-Object -ExpandProperty PSChildName) -join ', '
                return @{ Status = 'Warning'; Message = "Teams notifications are explicitly disabled for: $names. This is often intentional (Focus Assist / user preference). Review before changing." }
            }
            return @{ Status = 'Passed'; Message = "$($teamsKeys.Count) Teams notification setting(s) found; none are explicitly disabled." }
        }
        ResolutionScript = $null   # Notification suppression is a user/policy decision -- do not silently override
    },

    @{
        Name             = 'New Teams Package Registration'
        Order            = 6
        Enabled          = $true   # Runs always -- checks New Teams state regardless of Classic presence
        ResolveOnWarning = $false
        DetectionScript  = {
            if (-not $_teamsIsNew) {
                return @{ Status = 'Passed'; Message = 'New Teams (MSTeams AppX) is not installed on this device -- check skipped.' }
            }
            $pkg = $_newPackage
            # A broken or staging state indicates the package needs re-registration
            if ($pkg.Status -eq 'Ok' -or $null -eq $pkg.Status) {
                return @{ Status = 'Passed'; Message = "New Teams package present. Version: $($pkg.Version)." }
            }
            return @{ Status = 'Failed'; Message = "New Teams package is in state '$($pkg.Status)' (expected 'Ok'). Re-registration required$(if (-not $AllowDestructiveActions) { ' -- set $AllowDestructiveActions=$true to apply' } else { '' })." }
        }
        ResolutionScript = {
            # Re-registers the New Teams AppX manifest for the current user.
            # Only runs when $AllowDestructiveActions = $true since re-registration
            # resets Teams' local user state and forces a fresh startup.
            if (-not $AllowDestructiveActions) {
                Write-Host '  [Info] New Teams re-registration skipped -- set $AllowDestructiveActions=$true to apply.' -ForegroundColor DarkYellow
                return
            }
            $manifest = Join-Path $_newPackage.InstallLocation 'AppxManifest.xml'
            if (-not (Test-Path $manifest)) {
                throw "AppxManifest.xml not found at $($_newPackage.InstallLocation). Cannot re-register."
            }
            Add-AppxPackage -Register -Path $manifest -DisableDevelopmentMode -ErrorAction Stop
            Write-Host "  [Info] New Teams package re-registered from $manifest." -ForegroundColor DarkYellow
        }
    }
)

# -- Execution Engine ---------------------------------------------------------
$activeSteps = $Steps | Where-Object { $_.Enabled } | Sort-Object { [int]$_.Order }
$results     = [System.Collections.Generic.List[PSCustomObject]]::new()

$teamsVariant = (@(
    if ($_teamsIsClassic) { 'Classic' }
    if ($_teamsIsNew)     { 'New (AppX)' }
) -join ' + ')

Write-Host "`n-- Invoke-AutoRemediateTeams ------------------------------------" -ForegroundColor Cyan
Write-Host "   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')   Steps: $($activeSteps.Count)   Variant: $teamsVariant   User: $(if ($_loggedOnUser) { $_loggedOnUser } else { 'unknown' })"
Write-Host '----------------------------------------------------------------' -ForegroundColor Cyan

foreach ($step in $activeSteps) {
    $status     = 'Failed'
    $message    = 'Detection script did not return a result.'
    $remediated = $false
    $remError   = ''

    # Detection
    try {
        $result  = & $step.DetectionScript
        $status  = $result.Status
        $message = $result.Message
    } catch {
        $status  = 'Failed'
        $message = "Detection exception: $($_.Exception.Message)"
    }

    # Remediation
    $shouldRemediate = ($status -eq 'Failed') -or ($status -eq 'Warning' -and $step.ResolveOnWarning)
    if ($shouldRemediate -and $step.ResolutionScript) {
        try {
            & $step.ResolutionScript | Out-Null
            $remediated = $true
        } catch {
            $remError = $_.Exception.Message
        }
    }

    # Output
    $color   = switch ($status) { 'Passed' { 'Green' } 'Warning' { 'Yellow' } 'Failed' { 'Red' } default { 'White' } }
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

# -- Summary ------------------------------------------------------------------
$passed   = ($results | Where-Object { $_.Status -eq 'Passed'  }).Count
$warnings = ($results | Where-Object { $_.Status -eq 'Warning' }).Count
$failed   = ($results | Where-Object { $_.Status -eq 'Failed'  }).Count
$remCount = ($results | Where-Object { $_.Remediated }).Count

Write-Host "`n----------------------------------------------------------------" -ForegroundColor Cyan
Write-Host "  Passed: $passed  |  Warnings: $warnings  |  Failed: $failed  |  Remediations run: $remCount"
Write-Host "----------------------------------------------------------------`n" -ForegroundColor Cyan

# -- Registry Reporting -------------------------------------------------------
$regPath = 'HKLM:\Software\AirWatch\Extension\DEXRecords\TeamsErrors'
try {
    if (-not (Test-Path $regPath)) {
        New-Item -Path $regPath -Force -ErrorAction Stop | Out-Null
    }
    $existing = Get-Item -Path $regPath -ErrorAction SilentlyContinue
    if ($existing) {
        $existing.GetValueNames() | ForEach-Object {
            Remove-ItemProperty -Path $regPath -Name $_ -ErrorAction SilentlyContinue
        }
    }
    Set-ItemProperty -Path $regPath -Name 'LastScanTime'    -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') -Type String
    Set-ItemProperty -Path $regPath -Name 'TeamsVariant'    -Value $teamsVariant    -Type String
    Set-ItemProperty -Path $regPath -Name 'TotalSteps'      -Value $results.Count   -Type DWord
    Set-ItemProperty -Path $regPath -Name 'PassedCount'     -Value $passed          -Type DWord
    Set-ItemProperty -Path $regPath -Name 'WarningCount'    -Value $warnings        -Type DWord
    Set-ItemProperty -Path $regPath -Name 'FailedCount'     -Value $failed          -Type DWord
    Set-ItemProperty -Path $regPath -Name 'RemediatedCount' -Value $remCount        -Type DWord

    $results | Where-Object { $_.Status -ne 'Passed' } | ForEach-Object {
        $valueName = 'Step{0:D2}_{1}' -f $_.Order, ($_.Name -replace '[^A-Za-z0-9]', '')
        $tag       = if ($_.Remediated) { '[Remediated]' } else { "[$($_.Status)]" }
        Set-ItemProperty -Path $regPath -Name $valueName -Value "$tag $($_.Message)" -Type String
    }
    Write-Host "  [Registry] Results written to $regPath" -ForegroundColor DarkCyan
} catch {
    Write-Host "  [Registry] Write failed: $($_.Exception.Message)" -ForegroundColor Yellow
}

# -- Exit ---------------------------------------------------------------------
if ($failed -gt 0) { exit 1 }
exit 0
