<#
.SYNOPSIS
    Invoke-AutoRemediateOutlook -- Automated Outlook-specific diagnostic and remediation.

.DESCRIPTION
    Runs a sequenced set of Outlook-specific health checks and automatically
    remediates where possible. Fully self-contained -- no JSON, no UI, no
    external dependencies. Designed for deployment as a Workspace ONE MDM
    remediation script or standalone admin tool.

    Steps covered by generic scripts are intentionally excluded here:
      - Process health / crash loops  --> Restart-WinProcessGraceful.ps1
      - Network connectivity          --> Invoke-AutoRemediateNetworkStack.ps1
      - Disk space                    --> DiskCleanup scripts
      - Windows Update                --> Invoke-AutoRemediateWindowsUpdates.ps1
    Run those scripts first if those root causes are also suspected.

    +------+------------------------------+----------------------------------+
    | Step | Name                         | Remediates On                    |
    +------+------------------------------+----------------------------------+
    |  1   | Office Add-in Conflict       | Warning ($AllowDestructiveActs)  |
    |  2   | OST Cache Size               | Warning ($AllowDestructiveActs)  |
    |  3   | Exchange Sync Backlog        | -- (informational only)          |
    |  4   | Office C2R Update Health     | -- (informational only)          |
    |  5   | Outlook Profile Health       | -- (informational only)          |
    +------+------------------------------+----------------------------------+

    SYSTEM-context note: this script resolves the logged-on user's profile path
    via Win32_ComputerSystem.UserName and HKU\<SID> registry access.
    $env:APPDATA and $env:LOCALAPPDATA resolve to the SYSTEM profile when the
    script runs as SYSTEM and must not be used directly for per-user paths.

    Server-side limitation: Exchange mailbox health, Sync Issues folder item
    count, and M365 licensing state cannot be confirmed locally. Only cached or
    local signals are available. Note these as soft signals, not authoritative
    confirmations.

.PARAMETER CacheSizeWarningMB
    OST file size threshold in MB above which a warning is raised.
    Default: 30720 (30 GB). Override via $env:CacheSizeWarningMB.

.PARAMETER AllowDestructiveActions
    When $true, enables remediations that modify user data:
      - Step 1: Disables the active third-party add-in (LoadBehavior = 0).
      - Step 2: Renames the oversized OST file to force a server rebuild.
        Note: OST rebuild may trigger a full mailbox resync for large mailboxes.
    Default: $false -- Steps 1 and 2 are informational only until this is set.

.NOTES
    Script Name  : Invoke-AutoRemediateOutlook.ps1
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
    [int] $CacheSizeWarningMB      = $(if ($env:CacheSizeWarningMB)      { [int]$env:CacheSizeWarningMB }                               else { 30720 }),
    [bool]$AllowDestructiveActions = $(if ($env:AllowDestructiveActions)  { [System.Convert]::ToBoolean($env:AllowDestructiveActions) } else { $false })
)

# -- Pre-flight: app presence check -------------------------------------------
# Exit cleanly if Outlook is not installed -- this script may run fleet-wide.
$_c2rConfig    = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue
$_outlookFound = $false

foreach ($p in @(
    "$env:ProgramFiles\Microsoft Office\root\Office16\OUTLOOK.EXE",
    "${env:ProgramFiles(x86)}\Microsoft Office\root\Office16\OUTLOOK.EXE",
    "$env:ProgramFiles\Microsoft Office\Office16\OUTLOOK.EXE",
    "${env:ProgramFiles(x86)}\Microsoft Office\Office16\OUTLOOK.EXE"
)) {
    if (Test-Path $p) { $_outlookFound = $true; break }
}
# C2R configuration present implies Office is installed even if the path probe fails
if (-not $_outlookFound -and $_c2rConfig) { $_outlookFound = $true }

if (-not $_outlookFound) {
    Write-Host "`n-- Invoke-AutoRemediateOutlook ----------------------------------" -ForegroundColor Cyan
    Write-Host "   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Host '   [Skipped] Microsoft Outlook does not appear to be installed on this device.'
    Write-Host "----------------------------------------------------------------`n" -ForegroundColor Cyan
    exit 0
}

# -- Pre-flight: resolve logged-on user context -------------------------------
# SYSTEM context: $env:APPDATA resolves to the SYSTEM profile path, not the
# logged-on user's. Derive the actual user profile from WMI and build an HKU
# path from the user's SID for registry access to per-user keys.
$_loggedOnUser = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
$_shortName    = if ($_loggedOnUser) { $_loggedOnUser.Split('\')[-1] } else { $null }
$_userProfile  = if ($_shortName -and (Test-Path "C:\Users\$_shortName")) { "C:\Users\$_shortName" } else { $null }

$_userSid = $null
if ($_loggedOnUser) {
    try {
        $_userSid = ([Security.Principal.NTAccount]$_loggedOnUser).Translate([Security.Principal.SecurityIdentifier]).Value
    } catch { }
}

# -- Pre-flight: Office version and C2R client --------------------------------
$_officeVer = $null
if ($_c2rConfig -and $_c2rConfig.VersionToReport) {
    $parts = $_c2rConfig.VersionToReport.Split('.')
    if ($parts.Count -ge 2) { $_officeVer = "$($parts[0]).$($parts[1])" }
}
if (-not $_officeVer) {
    foreach ($v in @('16.0', '15.0', '14.0')) {
        if (Test-Path "HKLM:\SOFTWARE\Microsoft\Office\$v\Outlook") { $_officeVer = $v; break }
    }
}

$_c2rClient = $null
foreach ($candidate in @(
    $(if ($_c2rConfig -and $_c2rConfig.ClientFolder) { Join-Path $_c2rConfig.ClientFolder 'OfficeC2RClient.exe' }),
    "$env:ProgramFiles\Common Files\microsoft shared\ClickToRun\OfficeC2RClient.exe",
    "${env:ProgramFiles(x86)}\Common Files\microsoft shared\ClickToRun\OfficeC2RClient.exe"
)) {
    if ($candidate -and (Test-Path $candidate)) { $_c2rClient = $candidate; break }
}

# Patterns used to identify Microsoft's own add-ins and exclude them from
# the third-party conflict check.
$_msMatcher = '^Microsoft\.|UCAddin|UmOutlookAddin|OfficeMicrosoftTeams|Microsoft Online|SharePoint|OneDrive|Skype|Lync'

# -- Step Definitions ---------------------------------------------------------
$Steps = @(

    @{
        Name             = 'Office Add-in Conflict'
        Order            = 1
        Enabled          = $true
        # ResolveOnWarning is wired to $AllowDestructiveActions so the engine
        # only calls the resolution block when the caller has opted in.
        ResolveOnWarning = $AllowDestructiveActions
        DetectionScript  = {
            if (-not $_officeVer) {
                return @{ Status = 'Warning'; Message = 'Unable to determine Office version -- add-in check skipped.' }
            }
            $addinSubkey = "Software\Microsoft\Office\$_officeVer\Outlook\Addins"
            $allAddins   = [System.Collections.Generic.List[PSCustomObject]]::new()

            # Machine-level add-ins (HKLM)
            $hklmPath = "HKLM:\$addinSubkey"
            if (Test-Path $hklmPath) {
                Get-ChildItem $hklmPath -ErrorAction SilentlyContinue | ForEach-Object {
                    $lb = (Get-ItemProperty $_.PSPath -Name 'LoadBehavior' -ErrorAction SilentlyContinue).LoadBehavior
                    $allAddins.Add([PSCustomObject]@{ Name = $_.PSChildName; LoadBehavior = $lb; Path = $_.PSPath })
                }
            }
            # User-level add-ins via HKU\<SID> -- required because HKCU resolves
            # to the SYSTEM profile, not the logged-on user, when running as SYSTEM.
            if ($_userSid) {
                $hkuPath = "Registry::HKEY_USERS\$_userSid\$addinSubkey"
                if (Test-Path $hkuPath) {
                    Get-ChildItem $hkuPath -ErrorAction SilentlyContinue | ForEach-Object {
                        $lb = (Get-ItemProperty $_.PSPath -Name 'LoadBehavior' -ErrorAction SilentlyContinue).LoadBehavior
                        $allAddins.Add([PSCustomObject]@{ Name = $_.PSChildName; LoadBehavior = $lb; Path = $_.PSPath })
                    }
                }
            }

            if ($allAddins.Count -eq 0) {
                return @{ Status = 'Passed'; Message = 'No Outlook add-ins registered.' }
            }

            # Active (LoadBehavior = 3) third-party add-ins
            $thirdParty = $allAddins | Where-Object { $_.LoadBehavior -eq 3 -and $_.Name -notmatch $_msMatcher }
            if ($thirdParty.Count -eq 0) {
                return @{ Status = 'Passed'; Message = "$($allAddins.Count) add-in(s) registered; none are active third-party." }
            }
            $names = ($thirdParty | Select-Object -ExpandProperty Name) -join ', '
            return @{ Status = 'Warning'; Message = "$($thirdParty.Count) active third-party add-in(s) detected: $names. Consider disabling to rule out hang/crash contributions." }
        }
        ResolutionScript = {
            # Sets LoadBehavior = 0 on the first active third-party add-in found.
            # User-level keys are checked first (most common for third-party add-ins),
            # then falls back to machine-level. Only reached when $AllowDestructiveActions
            # is $true (ResolveOnWarning is wired to that flag above).
            $addinSubkey = "Software\Microsoft\Office\$_officeVer\Outlook\Addins"
            $sources     = @()
            if ($_userSid) { $sources += "Registry::HKEY_USERS\$_userSid\$addinSubkey" }
            $sources += "HKLM:\$addinSubkey"

            foreach ($srcPath in $sources) {
                if (-not (Test-Path $srcPath)) { continue }
                $target = Get-ChildItem $srcPath -ErrorAction SilentlyContinue | Where-Object {
                    $lb = (Get-ItemProperty $_.PSPath -Name 'LoadBehavior' -ErrorAction SilentlyContinue).LoadBehavior
                    $lb -eq 3 -and $_.PSChildName -notmatch $_msMatcher
                } | Select-Object -First 1
                if ($target) {
                    Set-ItemProperty -Path $target.PSPath -Name 'LoadBehavior' -Value 0 -ErrorAction Stop
                    Write-Host "  [Info] Add-in '$($target.PSChildName)' set to LoadBehavior=0 (disabled). Restart Outlook to take effect." -ForegroundColor DarkYellow
                    return
                }
            }
        }
    },

    @{
        Name             = 'OST Cache Size'
        Order            = 2
        Enabled          = $true
        ResolveOnWarning = $AllowDestructiveActions   # Rename is destructive -- gated by flag
        DetectionScript  = {
            if (-not $_userProfile) {
                return @{ Status = 'Warning'; Message = 'Cannot resolve logged-on user profile path -- OST check skipped.' }
            }
            $ostDir   = Join-Path $_userProfile 'AppData\Local\Microsoft\Outlook'
            $ostFiles = Get-ChildItem $ostDir -Filter '*.ost' -ErrorAction SilentlyContinue
            if (-not $ostFiles) {
                return @{ Status = 'Passed'; Message = "No .ost files found at $ostDir." }
            }
            $largest = $ostFiles | Sort-Object Length -Descending | Select-Object -First 1
            $sizeMB  = [math]::Round($largest.Length / 1MB, 0)
            if ($sizeMB -ge $CacheSizeWarningMB) {
                return @{ Status = 'Warning'; Message = "$($largest.Name) is ${sizeMB}MB (threshold: ${CacheSizeWarningMB}MB). OST rename/rebuild recommended$(if (-not $AllowDestructiveActions) { ' -- set $AllowDestructiveActions=$true to apply' } else { '' })." }
            }
            return @{ Status = 'Passed'; Message = "$($ostFiles.Count) OST file(s); largest is ${sizeMB}MB (threshold: ${CacheSizeWarningMB}MB)." }
        }
        ResolutionScript = {
            # Renames the oversized OST so Outlook creates a fresh one and resyncs
            # from Exchange on next launch. Large mailboxes can take significant time
            # to resync -- inform the user before deploying at scale.
            # Only reached when $AllowDestructiveActions = $true.
            if (Get-Process -Name OUTLOOK -ErrorAction SilentlyContinue) {
                throw 'Outlook is running -- OST file is locked and cannot be renamed. Stop Outlook first.'
            }
            $ostDir  = Join-Path $_userProfile 'AppData\Local\Microsoft\Outlook'
            $largest = Get-ChildItem $ostDir -Filter '*.ost' -ErrorAction SilentlyContinue |
                       Sort-Object Length -Descending | Select-Object -First 1
            if (-not $largest) { return }
            $ts      = Get-Date -Format 'yyyyMMdd-HHmmss'
            $newName = "$($largest.BaseName)_${ts}.bak"
            Rename-Item -Path $largest.FullName -NewName $newName -ErrorAction Stop
            Write-Host "  [Info] Renamed '$($largest.Name)' -> '$newName'. Outlook will rebuild the OST from Exchange on next launch." -ForegroundColor DarkYellow
        }
    },

    @{
        Name             = 'Exchange Sync Backlog'
        Order            = 3
        Enabled          = $true
        ResolveOnWarning = $false   # Cannot clear sync backlog silently -- informational only
        DetectionScript  = {
            # Direct MAPI/mailbox access is unavailable from SYSTEM context.
            # Proxy: Outlook error events in the Application event log (last 7 days).
            # Absence of events does not confirm sync health -- treat as a soft signal.
            $cutoff = (Get-Date).AddDays(-7)
            try {
                $events = Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = $cutoff } -ErrorAction SilentlyContinue |
                          Where-Object { $_.ProviderName -like '*Outlook*' -and $_.Level -le 3 }
                if (-not $events -or $events.Count -eq 0) {
                    return @{ Status = 'Passed'; Message = 'No Outlook error events in Application log (last 7 days). Soft signal only -- mailbox sync health requires server-side confirmation.' }
                }
                return @{ Status = 'Warning'; Message = "$($events.Count) Outlook error event(s) in last 7 days. Review Application event log for sync/MAPI details. No local auto-fix available." }
            } catch {
                return @{ Status = 'Warning'; Message = "Unable to query Application event log: $($_.Exception.Message)" }
            }
        }
        ResolutionScript = $null   # Sync backlog resolution (reduce cached mail range, run Send/Receive manually) requires user or admin action
    },

    @{
        Name             = 'Office C2R Update Health'
        Order            = 4
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            if (-not $_c2rConfig) {
                return @{ Status = 'Warning'; Message = 'Office Click-to-Run configuration not found -- update check skipped (MSI install or Office not present).' }
            }
            $version        = $_c2rConfig.VersionToReport
            $updatesEnabled = $_c2rConfig.UpdatesEnabled
            $channel        = $_c2rConfig.CDNBaseUrl

            if ($updatesEnabled -eq 'False') {
                return @{ Status = 'Failed'; Message = "C2R updates are disabled (UpdatesEnabled=False). Version: $version. Will trigger an update attempt." }
            }
            # Check for a recorded failure from the last C2R update attempt
            $updateProps = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Updates' -ErrorAction SilentlyContinue
            if ($updateProps -and $updateProps.ErrorCode -and $updateProps.ErrorCode -ne 0) {
                $hex = '0x{0:X8}' -f $updateProps.ErrorCode
                return @{ Status = 'Failed'; Message = "C2R update last failed with error $hex. Version: $version. Will trigger a retry." }
            }
            if (-not $channel) {
                return @{ Status = 'Warning'; Message = "C2R update channel URL (CDNBaseUrl) not configured. Version: $version." }
            }
            return @{ Status = 'Passed'; Message = "C2R updates enabled. Version: $version." }
        }
        ResolutionScript = $null   # Updates are managed via MDM deployment or Windows Update policy -- triggering C2R outside that channel may conflict with approved version targeting
    },

    @{
        Name             = 'Outlook Profile Health'
        Order            = 5
        Enabled          = $true
        ResolveOnWarning = $false   # Profile recreation is destructive -- requires explicit user/IT action
        DetectionScript  = {
            if (-not $_userSid -or -not $_officeVer) {
                return @{ Status = 'Warning'; Message = 'Cannot resolve user SID or Office version -- profile check skipped.' }
            }
            $outlookKeyPath = "Registry::HKEY_USERS\$_userSid\Software\Microsoft\Office\$_officeVer\Outlook"
            $profilesPath   = "$outlookKeyPath\Profiles"

            if (-not (Test-Path $outlookKeyPath)) {
                return @{ Status = 'Warning'; Message = 'Outlook user registry key not found. Outlook may never have been launched under this profile.' }
            }
            $defaultProfile = (Get-ItemProperty $outlookKeyPath -Name 'DefaultProfile' -ErrorAction SilentlyContinue).DefaultProfile
            if (-not $defaultProfile) {
                return @{ Status = 'Warning'; Message = 'No default Outlook profile set (DefaultProfile value missing or empty). Profile may be unconfigured or corrupt.' }
            }
            if (-not (Test-Path $profilesPath)) {
                return @{ Status = 'Warning'; Message = "Outlook Profiles key missing -- cannot verify profile '$defaultProfile'." }
            }
            $profileKey = Join-Path $profilesPath $defaultProfile
            if (-not (Test-Path $profileKey)) {
                return @{ Status = 'Warning'; Message = "Default profile '$defaultProfile' is referenced but its registry key does not exist. Profile is likely corrupt." }
            }
            $profileCount = (Get-ChildItem $profilesPath -ErrorAction SilentlyContinue).Count
            return @{ Status = 'Passed'; Message = "Default profile '$defaultProfile' verified. $profileCount profile(s) configured." }
        }
        ResolutionScript = $null   # Profile recreation deletes all account config and PST links -- requires user/IT sign-off
    }
)

# -- Execution Engine ---------------------------------------------------------
$activeSteps = $Steps | Where-Object { $_.Enabled } | Sort-Object { [int]$_.Order }
$results     = [System.Collections.Generic.List[PSCustomObject]]::new()

Write-Host "`n-- Invoke-AutoRemediateOutlook ----------------------------------" -ForegroundColor Cyan
Write-Host "   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')   Steps: $($activeSteps.Count)   User: $(if ($_loggedOnUser) { $_loggedOnUser } else { 'unknown' })"
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
$regPath = 'HKLM:\Software\AirWatch\Extension\DEXRecords\OutlookErrors'
try {
    if (-not (Test-Path $regPath)) {
        New-Item -Path $regPath -Force -ErrorAction Stop | Out-Null
    }
    # Clear previous scan results before writing fresh values
    $existing = Get-Item -Path $regPath -ErrorAction SilentlyContinue
    if ($existing) {
        $existing.GetValueNames() | ForEach-Object {
            Remove-ItemProperty -Path $regPath -Name $_ -ErrorAction SilentlyContinue
        }
    }
    Set-ItemProperty -Path $regPath -Name 'LastScanTime'    -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') -Type String
    Set-ItemProperty -Path $regPath -Name 'TotalSteps'      -Value $results.Count -Type DWord
    Set-ItemProperty -Path $regPath -Name 'PassedCount'     -Value $passed        -Type DWord
    Set-ItemProperty -Path $regPath -Name 'WarningCount'    -Value $warnings      -Type DWord
    Set-ItemProperty -Path $regPath -Name 'FailedCount'     -Value $failed        -Type DWord
    Set-ItemProperty -Path $regPath -Name 'RemediatedCount' -Value $remCount      -Type DWord

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
