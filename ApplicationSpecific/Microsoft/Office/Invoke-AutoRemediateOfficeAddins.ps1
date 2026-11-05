<#
.SYNOPSIS
    Invoke-AutoRemediateOfficeAddins -- Suite-wide Microsoft Office COM add-in and
    Resiliency (disabled items) diagnostic and remediation.

.DESCRIPTION
    The add-in logic the six per-app Office scripts (Word, Excel, PowerPoint, Access,
    OneNote, Publisher) used to carry, in one script, so each per-app script fits UEM's
    size limit and the destructive gate lives in one place. Outlook keeps its own step.
    Self-contained; built for Workspace ONE remediation or standalone use.

    | Step  | Name                              | Remediates On                      |
    |  1    | Word COM Add-in Conflict          | Warning/Failed ($AllowDestructive) |
    |  2    | Word Office-Disabled Items        | Warning ($ReenableDisabledItems)   |
    |  3-4  | Excel (same pair)                 |                                    |
    |  5-6  | PowerPoint (same pair)            |                                    |
    |  7-8  | Access (same pair)                |                                    |
    |  9-10 | OneNote (same pair)               |                                    |
    | 11-12 | Publisher (same pair)             |                                    |

    Pre-flight: no Click-to-Run configuration or root means "not installed, skipping",
    exit 0. An app whose exe is missing under the root keeps both its steps as Passed
    "<App> is not installed" so the step numbering is the same on every device.

    The Application log is read ONCE (1000/1002 from Application Error and Application
    Hang, last 7 days) through the .NET EventLogReader and grouped by faulting exe, so
    each app's add-in step knows its crash count and last faulting module. The add-in
    step goes Failed only when a crash names an add-in AND $AllowDestructiveActions is
    on (the engine remediates every Failed); otherwise it Warns. Add-in choice: the one
    the crash named, else the first active third-party one (user hive, then machine).

    SYSTEM context: the hive comes from Win32_ComputerSystem.UserName and HKU\<SID>,
    never $env:APPDATA. No interactive user: per-user steps Warn "skipped".

.PARAMETER AllowDestructiveActions
    Lets the add-in steps set LoadBehavior=0. Default $false. $env:AllowDestructiveActions.
.PARAMETER ReenableDisabledItems
    Lets the disabled-items steps clear Office's Resiliency entries. Default $false.
    $env:ReenableDisabledItems.
.PARAMETER CrashWarnCount7d
    Crash plus hang count in 7 days reported per app. Default 3. $env:CrashWarnCount7d.

.NOTES
    Script Name  : Invoke-AutoRemediateOfficeAddins.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-05 (1.0.0: add-in and Resiliency steps lifted out of the six per-app
                   Office scripts 1.0.2; one EventLogReader pass grouped by faulting exe;
                   _DecodeResiliency prefers the segment that is not a file path)
    Timeout      : 60 seconds

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

function Invoke-AutoRemediateOfficeAddins {
param(
    [bool]$AllowDestructiveActions = $(if ($env:AllowDestructiveActions) { [System.Convert]::ToBoolean($env:AllowDestructiveActions) } else { $false }),
    [bool]$ReenableDisabledItems   = $(if ($env:ReenableDisabledItems) { [System.Convert]::ToBoolean($env:ReenableDisabledItems) } else { $false }),
    [int] $CrashWarnCount7d        = $(if ($env:CrashWarnCount7d) { [int]$env:CrashWarnCount7d } else { 3 })
)

# -- Product identity --
$_ver  = '1.0.0'
$_apps = @(
    @{ App = 'Word';       Exe = 'WINWORD.EXE';  Reg = 'Word' },
    @{ App = 'Excel';      Exe = 'EXCEL.EXE';    Reg = 'Excel' },
    @{ App = 'PowerPoint'; Exe = 'POWERPNT.EXE'; Reg = 'PowerPoint' },
    @{ App = 'Access';     Exe = 'MSACCESS.EXE'; Reg = 'Access' },
    @{ App = 'OneNote';    Exe = 'ONENOTE.EXE';  Reg = 'OneNote' },
    @{ App = 'Publisher';  Exe = 'MSPUB.EXE';    Reg = 'Publisher' }
)
# Office's own modules; a fault in one of these is not an add-in's fault.
$_msModule = '^(wwlib|mso\w*|oart\w*|office|msvcr\w*|vcruntime\w*|ucrtbase|ntdll|kernelbase|kernel32|user32|gdi32|combase|ole32|oleaut32|rpcrt4|msvcp\w*|clr|coreclr|mscorwks|riched20|msptls|gfx|d2d1|dwrite|wwintl|mso20win32client|mso30win32client|mso40uiwin32client|mso50win32client|mso98win32client|mso99lwin32client|msointl\w*)\.dll$'
$_msAddin  = '^Microsoft\.|OfficeMicrosoftTeams|Microsoft Online|SharePoint|OneDrive|Skype|Lync|Grammarly\.Microsoft|CopilotAddin|PowerPivot|PowerMap|Inquire|NativeShim'

# -- Pre-flight: Click-to-Run --
$_c2rConfig = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue
$_c2rRoot   = $null
foreach ($p in @("$env:ProgramFiles\Microsoft Office\root\Office16", "${env:ProgramFiles(x86)}\Microsoft Office\root\Office16")) {
    if (Test-Path -LiteralPath $p) { $_c2rRoot = $p; break }
}
if (-not $_c2rConfig -or -not $_c2rRoot) {
    Write-Output "`r`n-- Invoke-AutoRemediateOfficeAddins -------------------------------"
    Write-Output "   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Output "   [Skipped] Click-to-Run Microsoft Office is not installed on this device."
    Write-Output "----------------------------------------------------------------`r`n"
    exit 0
}

# -- Pre-flight: logged-on user --
$_loggedOnUser = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
$_userSid      = $null
if ($_loggedOnUser) {
    try { $_userSid = ([Security.Principal.NTAccount]$_loggedOnUser).Translate([Security.Principal.SecurityIdentifier]).Value } catch { }
}
$_hku = if ($_userSid) { "Registry::HKEY_USERS\$_userSid" } else { $null }
$_officeVer = '16.0'
if ($_c2rConfig.VersionToReport) {
    $parts = $_c2rConfig.VersionToReport.Split('.')
    if ($parts.Count -ge 2) { $_officeVer = "$($parts[0]).$($parts[1])" }
}
$_noUser = @{ Status = 'Warning'; Message = 'No interactive user resolved -- per-user check skipped.' }

$regPath = 'HKLM:\Software\AirWatch\Extension\DEXRecords\OfficeAddinsErrors'

# -- Crash history: one Application log pass, grouped by faulting exe. Get-WinEvent fails under
# Hub's ARM64 PowerShell 7.2 engine, so the .NET EventLogReader with a server-side XPath filter. --
$script:_evWarn = ''
function _ReadCrashes {
    $by = @{}
    $t = (Get-Date).AddDays(-7).ToUniversalTime(); $t = $t.AddTicks(-($t.Ticks % [TimeSpan]::TicksPerSecond))
    $q = "*[System[(EventID=1000 or EventID=1002) and (Provider[@Name='Application Error'] or Provider[@Name='Application Hang']) and TimeCreated[@SystemTime>='$($t.ToString('o'))']]]"
    $reader = $null
    try {
        $eq = New-Object System.Diagnostics.Eventing.Reader.EventLogQuery('Application', [System.Diagnostics.Eventing.Reader.PathType]::LogName, $q)
        $eq.ReverseDirection = $true
        $reader = New-Object System.Diagnostics.Eventing.Reader.EventLogReader($eq)
        while ($null -ne ($r = $reader.ReadEvent())) {
            if ($r.Properties.Count -eq 0) { continue }
            $exe = "$($r.Properties[0].Value)".ToUpperInvariant()
            if (-not $by.ContainsKey($exe)) { $by[$exe] = @{ Count = 0; Hangs = 0; Crashes = 0; Module = ''; ModulePath = ''; ThirdParty = $false } }
            $c = $by[$exe]; $c.Count++
            if ($r.Id -eq 1002) { $c.Hangs++; continue }
            if ($c.Crashes -eq 0) {
                # Newest first: the first 1000 record seen is the last crash.
                $mod = ''; $modPath = ''
                if ($r.Properties.Count -gt 3)  { $mod     = "$($r.Properties[3].Value)" }
                if ($r.Properties.Count -gt 11) { $modPath = "$($r.Properties[11].Value)" }
                $c.Module     = $mod
                $c.ModulePath = $modPath
                $c.ThirdParty = [bool]($mod -and $mod -notmatch $_msModule -and $modPath -notmatch '\\Microsoft Office\\root\\|\\Common Files\\Microsoft Shared\\|\\Windows\\(System32|SysWOW64)\\')
            }
            $c.Crashes++
        }
    } catch {
        $script:_evWarn = "Unable to query the Application log: $($_.Exception.Message)"
    } finally {
        if ($reader) { $reader.Dispose() }
    }
    return $by
}
$_crashes = _ReadCrashes

function _Gate { if ($AllowDestructiveActions) { '' } else { ' -- set $AllowDestructiveActions=$true to apply' } }
function _AddinKeys([string]$reg) {
    # Every Addins key that can load into this product, user hive first.
    $out = @()
    $subs = @("Software\Microsoft\Office\$reg\Addins", "Software\Microsoft\Office\$_officeVer\$reg\Addins")
    foreach ($s in $subs) {
        if ($_hku) { $out += "$_hku\$s" }
        $out += "HKLM:\$s"
        $out += "HKLM:\SOFTWARE\WOW6432Node\$($s.Substring(9))"
    }
    return $out | Where-Object { Test-Path $_ }
}
function _ActiveThirdPartyAddins([string]$reg) {
    $list = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($k in @(_AddinKeys $reg)) {
        Get-ChildItem $k -ErrorAction SilentlyContinue | ForEach-Object {
            $lb = (Get-ItemProperty $_.PSPath -Name 'LoadBehavior' -ErrorAction SilentlyContinue).LoadBehavior
            if ($lb -eq 3 -and $_.PSChildName -notmatch $_msAddin) {
                $list.Add([PSCustomObject]@{ Name = $_.PSChildName; Path = $_.PSPath; Scope = $(if ($k -like 'Registry::*') { 'user' } else { 'machine' }) })
            }
        }
    }
    return $list
}
function _AddinNamedByCrash($addins, $crash) {
    # Match the faulting module's base name against the add-in ProgId tokens.
    if (-not $crash.ThirdParty -or -not $crash.Module) { return $null }
    $token = [IO.Path]::GetFileNameWithoutExtension($crash.Module)
    foreach ($a in $addins) {
        foreach ($part in ($a.Name -split '[.\s_-]')) {
            if ($part.Length -ge 4 -and ($token -like "*$part*" -or $part -like "*$token*")) { return $a }
        }
    }
    return $null
}
function _DecodeResiliency([string]$key) {
    # Binary blob: display name and path in UTF-16. Prefer the segment that is not a file path.
    $names = @()
    if (-not (Test-Path $key)) { return $names }
    $item = Get-Item $key -ErrorAction SilentlyContinue
    foreach ($v in $item.GetValueNames()) {
        $bytes = $item.GetValue($v)
        if ($bytes -is [byte[]]) {
            $text = [Text.Encoding]::Unicode.GetString($bytes)
            $segs = @($text -split "`0" | Where-Object { $_ -match '[A-Za-z]{3,}' })
            $pick = @($segs | Where-Object { $_ -notmatch '\\|\.dll$' })
            $names += $(if ($pick.Count -gt 0) { $pick[0].Trim() } elseif ($segs.Count -gt 0) { $segs[0].Trim() } else { $v })
        } else { $names += $v }
    }
    return $names
}

# -- Step bodies (shared by the six apps; $step is the engine's current step) --
$_detAddin = {
    $_app = $step.App
    if (-not $step.Installed) { return @{ Status = 'Passed'; Message = "$_app is not installed." } }
    $addins = @(_ActiveThirdPartyAddins $step.Reg)
    if ($addins.Count -eq 0) {
        return @{ Status = 'Passed'; Message = "No active third-party $_app add-ins (user and machine hives)." }
    }
    $named = _AddinNamedByCrash $addins $step.Crash
    $names = ($addins | ForEach-Object { "$($_.Name) [$($_.Scope)]" }) -join ', '
    if ($named) {
        # Failed only when the gate is open: the engine remediates every Failed.
        return @{ Status = $(if ($AllowDestructiveActions) { 'Failed' } else { 'Warning' }); Message = "Crash module $($step.Crash.Module) matches add-in '$($named.Name)'; $($addins.Count) active third-party add-in(s): $names. Will set LoadBehavior=0 on '$($named.Name)'$(_Gate)." }
    }
    return @{ Status = 'Warning'; Message = "$($addins.Count) active third-party add-in(s): $names. Disabling the first one is the remediation$(_Gate)." }
}
$_resAddin = {
    $addins = @(_ActiveThirdPartyAddins $step.Reg)
    if ($addins.Count -eq 0) { return @{ Remediated = $false } }
    $target = _AddinNamedByCrash $addins $step.Crash
    if (-not $target) { $target = $addins[0] }
    Set-ItemProperty -Path $target.Path -Name 'LoadBehavior' -Value 0 -ErrorAction Stop
    return @{ Remediated = $true; Message = "Add-in '$($target.Name)' [$($target.Scope)] set to LoadBehavior=0. Restart $($step.App) to take effect." }
}
$_detDisabled = {
    $_app = $step.App
    if (-not $step.Installed) { return @{ Status = 'Passed'; Message = "$_app is not installed." } }
    if (-not $_hku) { return $_noUser }
    $base = "$_hku\Software\Microsoft\Office\$_officeVer\$($step.Reg)\Resiliency"
    $disabled = @(_DecodeResiliency "$base\DisabledItems")
    $startup  = @(_DecodeResiliency "$base\StartupItems")
    if ($disabled.Count -eq 0 -and $startup.Count -eq 0) {
        return @{ Status = 'Passed'; Message = "$_app has not disabled any add-ins or startup items." }
    }
    $all = @($disabled + $startup | Select-Object -First 6) -join ', '
    $gate = if ($ReenableDisabledItems) { 'Clearing the entries so they load next launch.' } else { 'Set $ReenableDisabledItems=$true to clear them; Office disabled these after a failure, so confirm first.' }
    return @{ Status = 'Warning'; Message = "$($disabled.Count) disabled item(s), $($startup.Count) disabled startup item(s): $all. $gate" }
}
$_resDisabled = {
    $base = "$_hku\Software\Microsoft\Office\$_officeVer\$($step.Reg)\Resiliency"
    $n = 0
    foreach ($sub in 'DisabledItems', 'StartupItems') {
        $k = "$base\$sub"
        if (-not (Test-Path $k)) { continue }
        foreach ($v in (Get-Item $k).GetValueNames()) { Remove-ItemProperty -Path $k -Name $v -ErrorAction Stop; $n++ }
    }
    return @{ Remediated = ($n -gt 0); Message = "Cleared $n Resiliency entr$(if ($n -eq 1) { 'y' } else { 'ies' }); items load at $($step.App)'s next start." }
}

# -- Step Definitions: two per app, Order 2i-1 and 2i --
$Steps = @()
$i = 0
foreach ($a in $_apps) {
    $i++
    $exe   = $a.Exe.ToUpperInvariant()
    $crash = if ($_crashes.ContainsKey($exe)) { $_crashes[$exe] } else { @{ Count = 0; Hangs = 0; Crashes = 0; Module = ''; ModulePath = ''; ThirdParty = $false } }
    $inst  = Test-Path -LiteralPath (Join-Path $_c2rRoot $a.Exe)
    $Steps += @{ Name = "$($a.App) COM Add-in Conflict";   Order = 2 * $i - 1; App = $a.App; Reg = $a.Reg; Installed = $inst; Crash = $crash; Enabled = $true; ResolveOnWarning = $AllowDestructiveActions; DetectionScript = $_detAddin;    ResolutionScript = $_resAddin }
    $Steps += @{ Name = "$($a.App) Office-Disabled Items"; Order = 2 * $i;     App = $a.App; Reg = $a.Reg; Installed = $inst; Crash = $crash; Enabled = $true; ResolveOnWarning = $ReenableDisabledItems;   DetectionScript = $_detDisabled; ResolutionScript = $_resDisabled }
}

# -- Execution Engine --
$activeSteps = @($Steps | Where-Object { $_.Enabled } | Sort-Object { [int]$_.Order })
$results     = [System.Collections.Generic.List[PSCustomObject]]::new()

Write-Output "`r`n-- Invoke-AutoRemediateOfficeAddins -------------------------------"
Write-Output "   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')   Steps: $($activeSteps.Count)   User: $(if ($_loggedOnUser) { $_loggedOnUser } else { 'unknown' })   Office $($_c2rConfig.VersionToReport)"
Write-Output '----------------------------------------------------------------'
if ($script:_evWarn) { Write-Output "`r`n  [Warning] $($script:_evWarn) -- crash-to-add-in matching is off this run." }

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

# -- Registry Reporting --
try {
    if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force -ErrorAction Stop | Out-Null }
    $existing = Get-Item -Path $regPath -ErrorAction SilentlyContinue
    if ($existing) {
        $existing.GetValueNames() | ForEach-Object { Remove-ItemProperty -Path $regPath -Name $_ -ErrorAction SilentlyContinue }
    }
    Set-ItemProperty -Path $regPath -Name 'LastScanTime'    -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') -Type String
    Set-ItemProperty -Path $regPath -Name 'ScriptVersion'   -Value $_ver          -Type String
    Set-ItemProperty -Path $regPath -Name 'TotalSteps'      -Value $results.Count -Type DWord
    Set-ItemProperty -Path $regPath -Name 'PassedCount'     -Value $passed        -Type DWord
    Set-ItemProperty -Path $regPath -Name 'WarningCount'    -Value $warnings      -Type DWord
    Set-ItemProperty -Path $regPath -Name 'FailedCount'     -Value $failed        -Type DWord
    Set-ItemProperty -Path $regPath -Name 'RemediatedCount' -Value $remCount      -Type DWord
    foreach ($a in $_apps) {
        $c = $_crashes[$a.Exe.ToUpperInvariant()]
        if (-not $c) { continue }
        Set-ItemProperty -Path $regPath -Name "CrashCount7d_$($a.App)" -Value $c.Count -Type DWord
        if ($c.Module) { Set-ItemProperty -Path $regPath -Name "LastFaultModule_$($a.App)" -Value $c.Module -Type String }
    }

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

Invoke-AutoRemediateOfficeAddins
Exit 0
