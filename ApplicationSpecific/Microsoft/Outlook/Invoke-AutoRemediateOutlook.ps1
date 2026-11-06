<#
.SYNOPSIS
    Invoke-AutoRemediateOutlook -- Automated Outlook-specific diagnostic and remediation.

.DESCRIPTION
    Sequenced Outlook health checks with remediation where possible. Self-contained;
    built for Workspace ONE remediation or standalone use. Process health, network,
    disk and Windows Update belong to the generic scripts -- run those first.

    | Step | Name                         | Remediates On                    |
    |  1   | Office Add-in Conflict       | Warning ($AllowDestructiveActs)  |
    |  2   | OST Cache Size               | Warning ($AllowDestructiveActs)  |
    |  3   | Exchange Sync Backlog        | -- (informational only)          |
    |  4   | Office C2R Update Health     | DISABLED (Word script owns it)   |
    |  5   | Outlook Profile Health       | -- (informational only)          |

    STEP 2 TIERS (gated by $AllowDestructiveActions; largest OST over CacheSizeWarningMB)
    Tier 1  Sets the user's Cached Mode\SyncWindowSetting to OstSyncWindowMonths and
            records OstTier1AppliedAt; the OST shrinks once Outlook compacts it (days).
    Tier 2  After OstTier2AfterDays with AllowOstRename, renames the OST to
            <name>_<stamp>.bak for a FULL resync. Outlook open: Warning, unless
            CloseOutlookForRepair dispatches the deferred close ("Dispatched", exit 0).

    DEFERRED CLOSE HELPER: SYSTEM cannot message the user's Outlook, so the script
    writes C:\ProgramData\AirWatch\Extensions\Outlook\OstRepairHelper.ps1 (locked ACL)
    and runs it as the logged-on user through one-shot task DEX-OutlookOstRepair: toast,
    OutlookCloseGraceSeconds, CloseMainWindow for 60 s, never force-kill (still open:
    UserActionRequired), else rename, relaunch, write state\result.json. The next run
    ingests the result into DEXRecords (OstRepairLastOutcome/LastFinished) and cleans up.

    SYSTEM context: profile and hive come from Win32_ComputerSystem.UserName and
    HKU\<SID>, not $env:APPDATA. Steps 3-5 are soft signals.

.PARAMETER CacheSizeWarningMB
    OST threshold in MB. Default 30720. $env:CacheSizeWarningMB.
.PARAMETER AllowDestructiveActions
    Enables step 1 (LoadBehavior=0) and both step 2 tiers. Default $false.
.PARAMETER OstSyncWindowMonths
    Tier 1 window: 1, 3, 6, 12 or 24 (else 12). Default 12.
.PARAMETER OstTier2AfterDays
    Days after OstTier1AppliedAt before tier 2 is due. Default 7.
.PARAMETER AllowOstRename
    Permits tier 2. Default $false.
.PARAMETER CloseOutlookForRepair
    Permits the deferred close when tier 2 is due and Outlook is open. Default $false.
.PARAMETER OutlookCloseGraceSeconds
    Toast-to-close grace for the helper. Default 300. All inputs also read $env:.

.NOTES
    Script Name  : Invoke-AutoRemediateOutlook.ps1
    Version      : 1.1.2
    Architecture : Any (x86/x64/ARM64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-05 (1.1.2: step 3 reads the Application log through the .NET
                   EventLogReader; Get-WinEvent fails in every form under Hub's
                   PowerShell 7.2 engine on ARM64, which left the step inert in
                   production.)
                   2026-11-03 (1.1.1: step 3 event filter server-side; unfiltered ran 100+ s.)
                   2026-11-02 (1.1.0: two-tier step 2, deferred close helper, five new
                   inputs. 1.0.2: step 4 UpdatesEnabled=False is a Warning.)
                   2026-10-28 (1.0.1)
    Timeout      : 60 seconds

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>
function Invoke-AutoRemediateOutlook {
param(
    [int] $CacheSizeWarningMB       = $(if ($env:CacheSizeWarningMB) { [int]$env:CacheSizeWarningMB } else { 30720 }),
    [bool]$AllowDestructiveActions  = $(if ($env:AllowDestructiveActions) { [System.Convert]::ToBoolean($env:AllowDestructiveActions) } else { $false }),
    [int] $OstSyncWindowMonths      = $(if ($env:OstSyncWindowMonths) { [int]$env:OstSyncWindowMonths } else { 12 }),
    [int] $OstTier2AfterDays        = $(if ($env:OstTier2AfterDays) { [int]$env:OstTier2AfterDays } else { 7 }),
    [bool]$AllowOstRename           = $(if ($env:AllowOstRename) { [System.Convert]::ToBoolean($env:AllowOstRename) } else { $false }),
    [bool]$CloseOutlookForRepair    = $(if ($env:CloseOutlookForRepair) { [System.Convert]::ToBoolean($env:CloseOutlookForRepair) } else { $false }),
    [int] $OutlookCloseGraceSeconds = $(if ($env:OutlookCloseGraceSeconds) { [int]$env:OutlookCloseGraceSeconds } else { 300 })
)

# -- Pre-flight: app presence --
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
if (-not $_outlookFound -and $_c2rConfig) { $_outlookFound = $true }

if (-not $_outlookFound) {
    Write-Output "`r`n-- Invoke-AutoRemediateOutlook ----------------------------------"
    Write-Output "   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Output '   [Skipped] Microsoft Outlook does not appear to be installed on this device.'
    Write-Output "----------------------------------------------------------------`r`n"
    exit 0
}

# -- Pre-flight: logged-on user --
$_loggedOnUser = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
$_shortName    = if ($_loggedOnUser) { $_loggedOnUser.Split('\')[-1] } else { $null }
$_userProfile  = if ($_shortName -and (Test-Path "C:\Users\$_shortName")) { "C:\Users\$_shortName" } else { $null }
$_userSid      = $null
if ($_loggedOnUser) {
    try { $_userSid = ([Security.Principal.NTAccount]$_loggedOnUser).Translate([Security.Principal.SecurityIdentifier]).Value } catch { }
}

# -- Pre-flight: Office version and C2R client --
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

# Microsoft's own add-ins, excluded from step 1.
$_msMatcher = '^Microsoft\.|UCAddin|UmOutlookAddin|OfficeMicrosoftTeams|Microsoft Online|SharePoint|OneDrive|Skype|Lync'

# -- Pre-flight: DEXRecords key, tier state, deferred-close result --
$regPath     = 'HKLM:\Software\AirWatch\Extension\DEXRecords\OutlookErrors'
$_helperDir  = 'C:\ProgramData\AirWatch\Extensions\Outlook'
$_resultPath = "$_helperDir\state\result.json"
$_taskName   = 'DEX-OutlookOstRepair'
if ($OstSyncWindowMonths -notin 1, 3, 6, 12, 24) { $OstSyncWindowMonths = 12 }
if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force -ErrorAction SilentlyContinue | Out-Null }
if (Test-Path $_resultPath) {
    try {
        $r = Get-Content $_resultPath -Raw | ConvertFrom-Json
        if ("$($r.Finished)" -ne "$((Get-ItemProperty $regPath -ErrorAction SilentlyContinue).OstRepairLastFinished)") {
            Set-ItemProperty -Path $regPath -Name 'OstRepairLastOutcome'  -Value "$($r.Outcome)"  -Type String
            Set-ItemProperty -Path $regPath -Name 'OstRepairLastFinished' -Value "$($r.Finished)" -Type String
        }
        Remove-Item $_resultPath -Force
        $t = Get-ScheduledTask -TaskName $_taskName -ErrorAction SilentlyContinue
        if ($t -and $t.State -ne 'Running') { Unregister-ScheduledTask -TaskName $_taskName -Confirm:$false -ErrorAction SilentlyContinue }
    } catch { }
}

# Deferred-close helper, persisted to disk and run as the logged-on user (Limited).
$_helperSrc = @'
param([string]$OstPath, [int]$GraceSeconds = 300, [string]$ResultPath, [string]$TaskName)
# OstRepairHelper.ps1 -- written by Invoke-AutoRemediateOutlook.ps1. No HKLM, no force-kill.
$started = (Get-Date).ToString('o'); $renamed = ''; $tries = 0
function Write-Result([string]$Status, [string]$Outcome) {
    $d = Split-Path $ResultPath -Parent
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    @{ Status = $Status; Outcome = $Outcome; Ost = $OstPath; RenamedTo = $renamed; CloseAttempts = $tries; Started = $started; Finished = (Get-Date).ToString('o') } |
        ConvertTo-Json | Set-Content -Path $ResultPath -Encoding UTF8 -Force
}
try {
    try {
        $null = [Windows.UI.Notifications.ToastNotificationManager,Windows.UI.Notifications,ContentType=WindowsRuntime]
        $null = [Windows.Data.Xml.Dom.XmlDocument,Windows.Data.Xml.Dom.XmlDocument,ContentType=WindowsRuntime]
        $mins = [math]::Max(1, [math]::Ceiling($GraceSeconds / 60))
        $doc  = New-Object Windows.Data.Xml.Dom.XmlDocument
        $doc.LoadXml("<toast><visual><binding template='ToastGeneric'><text>Mailbox maintenance</text><text>Outlook will close in $mins minute(s) for mailbox maintenance. Save your work.</text></binding></visual></toast>")
        $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        $hub = Get-StartApps | Where-Object Name -like 'Workspace ONE Intelligent Hub' | Select-Object -First 1
        if ($hub) { $appId = $hub.AppId }
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($doc)
    } catch { }
    Start-Sleep -Seconds $GraceSeconds
    $exe = (Get-Process -Name OUTLOOK -ErrorAction SilentlyContinue | Select-Object -First 1).Path
    $deadline = (Get-Date).AddSeconds(60)
    do {
        Get-Process -Name OUTLOOK -ErrorAction SilentlyContinue | ForEach-Object { $null = $_.CloseMainWindow() }
        $tries++; $next = (Get-Date).AddSeconds(10)
        while ((Get-Process -Name OUTLOOK -ErrorAction SilentlyContinue) -and (Get-Date) -lt $next) { Start-Sleep -Seconds 2 }
    } while ((Get-Process -Name OUTLOOK -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline)
    if (Get-Process -Name OUTLOOK -ErrorAction SilentlyContinue) {
        Write-Result 'Warning' 'UserActionRequired'
    } else {
        $outcome = 'OstMissing'
        if (Test-Path -LiteralPath $OstPath) {
            $f = Get-Item -LiteralPath $OstPath
            $new = "$($f.BaseName)_$(Get-Date -Format 'yyyyMMdd-HHmmss').bak"
            Rename-Item -LiteralPath $OstPath -NewName $new -ErrorAction Stop
            $renamed = Join-Path $f.DirectoryName $new; $outcome = 'Renamed'
        }
        if ($exe) { Start-Process -FilePath $exe | Out-Null }
        Write-Result 'Passed' $outcome
    }
} catch {
    Write-Result 'Failed' "Error: $($_.Exception.Message)"
} finally {
    if ($TaskName) { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue }
}
'@

# Step 2 plan shared by detection and resolution. Tier: 0 healthy, 1 window, 'Wait', 2 rename.
$_ostPlan = {
    $dir   = Join-Path $_userProfile 'AppData\Local\Microsoft\Outlook'
    $files = @(Get-ChildItem $dir -Filter '*.ost' -ErrorAction SilentlyContinue)
    $p = @{ Dir = $dir; Count = $files.Count; Tier = 0 }
    if ($files.Count -eq 0) { return $p }
    $p.Largest = $files | Sort-Object Length -Descending | Select-Object -First 1
    $p.SizeMB  = [math]::Round($p.Largest.Length / 1MB, 0)
    if ($p.SizeMB -lt $CacheSizeWarningMB) { return $p }
    $cm = Get-ItemProperty "Registry::HKEY_USERS\$_userSid\Software\Microsoft\Office\$_officeVer\Outlook\Cached Mode" -ErrorAction SilentlyContinue
    $p.Window = if ($cm -and $null -ne $cm.SyncWindowSetting) { [int]$cm.SyncWindowSetting } else { -1 }
    $p.T1At   = (Get-ItemProperty $regPath -ErrorAction SilentlyContinue).OstTier1AppliedAt
    if ($p.Window -le 0 -or $p.Window -gt $OstSyncWindowMonths -or -not $p.T1At) { $p.Tier = 1; return $p }
    $p.DueIn = $OstTier2AfterDays - ((Get-Date) - [datetime]$p.T1At).TotalDays
    $p.Tier  = if ($p.DueIn -gt 0) { 'Wait' } else { 2 }
    $p.OutlookOpen = [bool](Get-Process -Name OUTLOOK -ErrorAction SilentlyContinue)
    return $p
}

# -- Step Definitions --
$Steps = @(

    @{
        Name             = 'Office Add-in Conflict'
        Order            = 1
        Enabled          = $true
        ResolveOnWarning = $AllowDestructiveActions
        DetectionScript  = {
            if (-not $_officeVer) {
                return @{ Status = 'Warning'; Message = 'Unable to determine Office version -- add-in check skipped.' }
            }
            $addinSubkey = "Software\Microsoft\Office\$_officeVer\Outlook\Addins"
            $allAddins   = [System.Collections.Generic.List[PSCustomObject]]::new()
            $hklmPath = "HKLM:\$addinSubkey"
            if (Test-Path $hklmPath) {
                Get-ChildItem $hklmPath -ErrorAction SilentlyContinue | ForEach-Object {
                    $lb = (Get-ItemProperty $_.PSPath -Name 'LoadBehavior' -ErrorAction SilentlyContinue).LoadBehavior
                    $allAddins.Add([PSCustomObject]@{ Name = $_.PSChildName; LoadBehavior = $lb; Path = $_.PSPath })
                }
            }
            # User add-ins via HKU\<SID>; HKCU is SYSTEM's own hive here.
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
            # @(): one pipeline object has no .Count in PS 5.1.
            $thirdParty = @($allAddins | Where-Object { $_.LoadBehavior -eq 3 -and $_.Name -notmatch $_msMatcher })
            if ($thirdParty.Count -eq 0) {
                return @{ Status = 'Passed'; Message = "$($allAddins.Count) add-in(s) registered; none are active third-party." }
            }
            $names = ($thirdParty | Select-Object -ExpandProperty Name) -join ', '
            return @{ Status = 'Warning'; Message = "$($thirdParty.Count) active third-party add-in(s) detected: $names. Consider disabling to rule out hang/crash contributions." }
        }
        ResolutionScript = {
            # LoadBehavior = 0 on the first active third-party add-in; user hive, then HKLM.
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
                    Write-Output "  [Info] Add-in '$($target.PSChildName)' set to LoadBehavior=0 (disabled). Restart Outlook to take effect."
                    return
                }
            }
        }
    },

    @{
        Name             = 'OST Cache Size'
        Order            = 2
        Enabled          = $true
        ResolveOnWarning = $AllowDestructiveActions
        DetectionScript  = {
            if (-not $_userProfile -or -not $_userSid -or -not $_officeVer) {
                return @{ Status = 'Warning'; Message = 'Cannot resolve logged-on user profile, SID or Office version -- OST check skipped.' }
            }
            $p = & $_ostPlan
            if ($p.Count -eq 0) {
                return @{ Status = 'Passed'; Message = "No .ost files found at $($p.Dir)." }
            }
            if ($p.Tier -eq 0) {
                return @{ Status = 'Passed'; Message = "$($p.Count) OST file(s); largest is $($p.SizeMB)MB (threshold: ${CacheSizeWarningMB}MB)." }
            }
            $head = "$($p.Largest.Name) is $($p.SizeMB)MB (threshold: ${CacheSizeWarningMB}MB)."
            $gate = if ($AllowDestructiveActions) { '' } else { ' -- set $AllowDestructiveActions=$true to apply' }
            $msg  = switch ("$($p.Tier)") {
                '1'    { "Tier 1: set Cached Mode SyncWindowSetting=$OstSyncWindowMonths month(s) (current: $(if ($p.Window -lt 0) { 'default' } elseif ($p.Window -eq 0) { 'all' } else { "$($p.Window) month(s)" })); effective at Outlook's next start, the OST shrinks after Outlook compacts it$gate." }
                'Wait' { "Tier 1 applied $($p.T1At); tier 2 (rename) due in $([math]::Ceiling($p.DueIn)) day(s)." }
                default {
                    if (-not $AllowOstRename)            { "Tier 2 (rename) due since tier 1 on $($p.T1At); set `$AllowOstRename=`$true to allow it." }
                    elseif (-not $p.OutlookOpen)         { "Tier 2: rename to $($p.Largest.BaseName)_<stamp>.bak; Outlook rebuilds the OST on next launch (full resync)$gate." }
                    elseif (-not $CloseOutlookForRepair) { 'Tier 2 due, Outlook open; set $CloseOutlookForRepair=$true to allow a deferred close.' }
                    else                                 { "Tier 2 due, Outlook open; deferred close ($OutlookCloseGraceSeconds s grace) will be dispatched$gate." }
                }
            }
            return @{ Status = 'Warning'; Message = "$head $msg" }
        }
        ResolutionScript = {
            # Returns @{ Remediated; [Status]; [Message] }.
            $p = & $_ostPlan
            if ($p.Tier -eq 1) {
                $cm = "Registry::HKEY_USERS\$_userSid\Software\Microsoft\Office\$_officeVer\Outlook\Cached Mode"
                if (-not (Test-Path $cm)) { New-Item -Path $cm -Force -ErrorAction Stop | Out-Null }
                Set-ItemProperty -Path $cm -Name 'SyncWindowSetting' -Value $OstSyncWindowMonths -Type DWord -ErrorAction Stop
                Remove-ItemProperty -Path $cm -Name 'SyncWindowSettingDays' -ErrorAction SilentlyContinue
                Set-ItemProperty -Path $regPath -Name 'OstTier1AppliedAt' -Value (Get-Date).ToString('o') -Type String -ErrorAction Stop
                return @{ Remediated = $true }
            }
            if ($p.Tier -ne 2 -or -not $AllowOstRename) { return @{ Remediated = $false } }
            if (-not $p.OutlookOpen) {
                $newName = "$($p.Largest.BaseName)_$(Get-Date -Format 'yyyyMMdd-HHmmss').bak"
                Rename-Item -Path $p.Largest.FullName -NewName $newName -ErrorAction Stop
                return @{ Remediated = $true; Message = "$($p.Largest.Name) ($($p.SizeMB)MB) renamed to $newName; Outlook rebuilds the OST on next launch (full resync)." }
            }
            if (-not $CloseOutlookForRepair) { return @{ Remediated = $false } }
            $t = Get-ScheduledTask -TaskName $_taskName -ErrorAction SilentlyContinue
            if ($t -and $t.State -eq 'Running') { return @{ Status = 'Warning'; Message = 'Deferred Outlook close already in progress.'; Remediated = $false } }
            if ($t) { Unregister-ScheduledTask -TaskName $_taskName -Confirm:$false -ErrorAction SilentlyContinue }
            foreach ($d in @($_helperDir, "$_helperDir\state")) {
                if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force -ErrorAction Stop | Out-Null }
                $acl = Get-Acl $d; $acl.SetAccessRuleProtection($true, $false)
                $usersRight = if ($d -eq $_helperDir) { 'ReadAndExecute' } else { 'Modify' }
                foreach ($r in @(@('NT AUTHORITY\SYSTEM', 'FullControl'), @('BUILTIN\Administrators', 'FullControl'), @('BUILTIN\Users', $usersRight))) {
                    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($r[0], $r[1], 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
                }
                Set-Acl -Path $d -AclObject $acl -ErrorAction Stop
            }
            Set-Content -Path "$_helperDir\OstRepairHelper.ps1" -Value $_helperSrc -Encoding UTF8 -Force -ErrorAction Stop
            $arg = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$_helperDir\OstRepairHelper.ps1`" -OstPath `"$($p.Largest.FullName)`" -GraceSeconds $OutlookCloseGraceSeconds -ResultPath `"$_resultPath`" -TaskName $_taskName"
            Register-ScheduledTask -TaskName $_taskName -Force -ErrorAction Stop `
                -Action    (New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg) `
                -Principal (New-ScheduledTaskPrincipal -UserId $_loggedOnUser -LogonType Interactive -RunLevel Limited) `
                -Settings  (New-ScheduledTaskSettingsSet -Hidden -AllowStartIfOnBatteries -ExecutionTimeLimit (New-TimeSpan -Seconds ($OutlookCloseGraceSeconds + 900))) | Out-Null
            Start-ScheduledTask -TaskName $_taskName -ErrorAction Stop
            return @{ Status = 'Warning'; Remediated = $false; Message = "Dispatched: Outlook closes in $OutlookCloseGraceSeconds s for OST repair ($($p.Largest.Name), $($p.SizeMB)MB); outcome lands in DEXRecords OstRepairLastOutcome on the next run." }
        }
    },

    @{
        Name             = 'Exchange Sync Backlog'
        Order            = 3
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            # No MAPI from SYSTEM; Outlook error events (7 days) are the proxy. .NET reader:
            # Get-WinEvent fails in every form under Hub's ARM64 engine (13.2.z).
            $cutoff = (Get-Date).AddDays(-7)
            try {
                $since  = $cutoff.ToUniversalTime().ToString('o')
                $xpath  = "*[System[(Level=1 or Level=2 or Level=3) and TimeCreated[@SystemTime>='$since']]]"
                $query  = New-Object System.Diagnostics.Eventing.Reader.EventLogQuery('Application', [System.Diagnostics.Eventing.Reader.PathType]::LogName, $xpath)
                $reader = New-Object System.Diagnostics.Eventing.Reader.EventLogReader($query)
                $events = New-Object System.Collections.Generic.List[int]
                try {
                    while ($null -ne ($record = $reader.ReadEvent())) {
                        if ($record.ProviderName -like '*Outlook*') { $events.Add($record.Id) }
                        $record.Dispose()
                    }
                } finally { $reader.Dispose() }
                if ($events.Count -eq 0) {
                    return @{ Status = 'Passed'; Message = 'No Outlook error events in Application log (last 7 days). Soft signal only -- mailbox sync health requires server-side confirmation.' }
                }
                return @{ Status = 'Warning'; Message = "$($events.Count) Outlook error event(s) in last 7 days. Review Application event log for sync/MAPI details. No local auto-fix available." }
            } catch {
                return @{ Status = 'Warning'; Message = "Unable to query Application event log: $($_.Exception.Message)" }
            }
        }
        ResolutionScript = $null
    },

    @{
        Name             = 'Office C2R Update Health'
        Order            = 4
        Enabled          = $false   # suite-wide: Invoke-AutoRemediateWord owns it
        ResolveOnWarning = $false
        DetectionScript  = {
            if (-not $_c2rConfig) {
                return @{ Status = 'Warning'; Message = 'Office Click-to-Run configuration not found -- update check skipped (MSI install or Office not present).' }
            }
            $version        = $_c2rConfig.VersionToReport
            $updatesEnabled = $_c2rConfig.UpdatesEnabled
            $channel        = $_c2rConfig.CDNBaseUrl
            # Warning, not Failed: no resolution exists; policy-managed devices live here.
            if ($updatesEnabled -eq 'False') {
                return @{ Status = 'Warning'; Message = "C2R updates are disabled (UpdatesEnabled=False). Version: $version. Updates are managed by policy or MDM outside this script -- no remediation attempted." }
            }
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
        ResolutionScript = $null   # updates belong to MDM / policy
    },

    @{
        Name             = 'Outlook Profile Health'
        Order            = 5
        Enabled          = $true
        ResolveOnWarning = $false
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
            $profileCount = @(Get-ChildItem $profilesPath -ErrorAction SilentlyContinue).Count
            return @{ Status = 'Passed'; Message = "Default profile '$defaultProfile' verified. $profileCount profile(s) configured." }
        }
        ResolutionScript = $null   # profile recreation deletes account config
    }
)

# -- Execution Engine --
$activeSteps = @($Steps | Where-Object { $_.Enabled } | Sort-Object { [int]$_.Order })
$results     = [System.Collections.Generic.List[PSCustomObject]]::new()

Write-Output "`r`n-- Invoke-AutoRemediateOutlook ----------------------------------"
Write-Output "   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')   Steps: $($activeSteps.Count)   User: $(if ($_loggedOnUser) { $_loggedOnUser } else { 'unknown' })"
Write-Output '----------------------------------------------------------------'

foreach ($step in $activeSteps) {
    $status     = 'Failed'
    $message    = 'Detection script did not return a result.'
    $remediated = $false
    $remError   = ''

    try {
        $result  = & $step.DetectionScript
        $status  = $result.Status
        $message = $result.Message
    } catch {
        $status  = 'Failed'
        $message = "Detection exception: $($_.Exception.Message)"
    }

    # A ResolutionScript may return @{ Remediated; Status; Message }; anything else = remediated.
    $shouldRemediate = ($status -eq 'Failed') -or ($status -eq 'Warning' -and $step.ResolveOnWarning)
    if ($shouldRemediate -and $step.ResolutionScript) {
        try {
            $rr = & $step.ResolutionScript | Select-Object -Last 1
            if ($rr -is [hashtable]) {
                $remediated = [bool]$rr.Remediated
                if ($rr.Status)  { $status  = $rr.Status }
                if ($rr.Message) { $message = $rr.Message }
            } else { $remediated = $true }
        } catch {
            $remError = $_.Exception.Message
        }
    }

    $color   = switch ($status) { 'Passed' { 'Green' } 'Warning' { 'Yellow' } 'Failed' { 'Red' } default { 'White' } }
    $remNote = if ($remediated)   { '  -> Remediation ran' }
               elseif ($remError) { "  -> Remediation ERROR: $remError" }
               else               { '' }
    Write-Output "`r`n  [$($status.PadRight(7))] $($step.Name): $message$remNote"

    $results.Add([PSCustomObject]@{
        Order      = $step.Order
        Name       = $step.Name
        Status     = $status
        Message    = $message
        Remediated = $remediated
        RemError   = $remError
    })
}

# -- Summary --
$passed   = @($results | Where-Object { $_.Status -eq 'Passed'  }).Count
$warnings = @($results | Where-Object { $_.Status -eq 'Warning' }).Count
$failed   = @($results | Where-Object { $_.Status -eq 'Failed'  }).Count
$remCount = @($results | Where-Object { $_.Remediated }).Count

Write-Output "`r`n----------------------------------------------------------------"
Write-Output "  Passed: $passed  |  Warnings: $warnings  |  Failed: $failed  |  Remediations run: $remCount"
Write-Output "----------------------------------------------------------------`r`n"

# -- Registry Reporting; Ost* values persist --
try {
    if (-not (Test-Path $regPath)) {
        New-Item -Path $regPath -Force -ErrorAction Stop | Out-Null
    }
    $existing = Get-Item -Path $regPath -ErrorAction SilentlyContinue
    if ($existing) {
        $existing.GetValueNames() | Where-Object { $_ -notlike 'Ost*' } | ForEach-Object {
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
    Write-Output "  [Registry] Results written to $regPath"
} catch {
    Write-Output "  [Registry] Write failed: $($_.Exception.Message)"
}

if ($failed -gt 0) { exit 1 }
exit 0
}

# -- entry point (params live inside the function: UEM ignores script-scope params)

Invoke-AutoRemediateOutlook
Exit 0
