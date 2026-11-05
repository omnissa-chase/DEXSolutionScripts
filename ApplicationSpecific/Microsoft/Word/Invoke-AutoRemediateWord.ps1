<#
.SYNOPSIS
    Invoke-AutoRemediateWord -- Automated Microsoft Word diagnostic and remediation.

.DESCRIPTION
    Sequenced Word health checks with remediation where safe. Self-contained; built for
    Workspace ONE remediation or standalone use. Network, disk, memory and Windows
    Update belong to the generic scripts -- run those first.

    | Step | Name                         | Remediates On                       |
    |  2   | Crash and Hang History       | -- (report only; feeds 3, 6, 9)     |
    |  3   | COM Add-in Conflict          | Warning/Failed ($AllowDestructive)  |
    |  4   | Office-Disabled Items        | Warning ($ReenableDisabledItems)    |
    |  5   | AutoRecover Location         | Warning                             |
    |  6   | Normal.dotm Health           | Warning ($AllowDestructive)         |
    |  7   | Office Document Cache        | Warning ($AllowDestructive)         |
    |  8   | Office C2R Update Health     | -- (report only)                    |
    |  9   | Word Data Key                | Warning ($AllowDestructive)         |
    | 10   | Startup Folder               | -- (report only)                    |

    Step 1 (app installed) is the pre-flight: no WINWORD.EXE under the Click-to-Run
    root means "not installed, skipping", exit 0.

    Steps 2-8 are the common Office steps (spec C2-C8) with Word's names hard-coded;
    the other five Office scripts carry the same engine. Steps 7 and 8 are suite-wide
    and ENABLED ONLY HERE. One script per product until UEM has dynamic variables.

    Step 2 keeps the last faulting module. Step 3 goes Failed and targets the add-in
    whose name matches a non-Microsoft module; step 6 treats wwlib.dll faults with no
    add-in blamed as a template suspect; step 9 fires only when 3, 4 and 6 found
    nothing. Add-in choice: the one step 2 named, else the first active third-party
    one (user hive, then machine) -- key write times are not readable without P/Invoke.

    SYSTEM context: profile and hive come from Win32_ComputerSystem.UserName and
    HKU\<SID>, never $env:APPDATA. No interactive user: per-user steps Warn "skipped".

.PARAMETER CacheSizeWarningMB
    Office Document Cache threshold in MB. Default 2048. $env:CacheSizeWarningMB.
.PARAMETER AllowDestructiveActions
    Enables steps 3, 6, 7 and 9. Default $false. $env:AllowDestructiveActions.
.PARAMETER CrashWarnCount7d
    Crash plus hang count in 7 days that turns step 2 Failed. Default 3.
.PARAMETER TemplateWarnMB
    Normal.dotm size that turns step 6 Warning. Default 8.
.PARAMETER ReenableDisabledItems
    Lets step 4 clear Office's Resiliency entries. Default $false. All inputs also
    read $env:.

.NOTES
    Script Name  : Invoke-AutoRemediateWord.ps1
    Version      : 1.0.1
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-05 (1.0.1: crash and hang events read through the .NET EventLogReader; Get-WinEvent fails in every form under Hub's ARM64 PowerShell 7.2 engine; 1.0.0: first build from App_Remediation_Specs.md section 8)
    Timeout      : 60 seconds

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>
#region --- Event log reader --------------------------------------------------------------------
# Get-WinEvent fails in every form under Hub's ARM64 PowerShell 7.2 engine ("Cannot marshal
# 'parameter #8'"), so events are read through System.Diagnostics.Eventing.Reader, which behaves
# the same on Windows PowerShell 5.1 and PowerShell 7. Get-WinEvent semantics are kept: newest
# first unless -Oldest, StartTime/EndTime are whole-second bounds, a failed read yields an empty
# result unless -ErrorStop. Each record carries a Message property (FormatDescription(), falling
# back to the raw property values when the provider ships no message metadata).
function Get-DexEvent {
    param(
        [Parameter(Mandatory = $true)][string]$LogName,
        [int[]]$Id,
        [string[]]$ProviderName,
        [int[]]$Level,
        [datetime]$StartTime,
        [datetime]$EndTime,
        [string]$XPath,
        [int]$MaxEvents = 0,
        [switch]$Oldest,
        [switch]$ErrorStop
    )
    $sys = New-Object System.Collections.Generic.List[string]
    if ($Id)           { $sys.Add('(' + (@($Id | ForEach-Object { "EventID=$_" }) -join ' or ') + ')') }
    if ($ProviderName) { $sys.Add('(' + (@($ProviderName | ForEach-Object { "Provider[@Name='$_']" }) -join ' or ') + ')') }
    if ($Level)        { $sys.Add('(' + (@($Level | ForEach-Object { "Level=$_" }) -join ' or ') + ')') }
    $when = New-Object System.Collections.Generic.List[string]
    if ($PSBoundParameters.ContainsKey('StartTime')) {
        $t = $StartTime.ToUniversalTime(); $t = $t.AddTicks(-($t.Ticks % [TimeSpan]::TicksPerSecond))
        $when.Add("@SystemTime>='" + $t.ToString('o') + "'")
    }
    if ($PSBoundParameters.ContainsKey('EndTime')) {
        $t = $EndTime.ToUniversalTime()
        if ($t.Ticks % [TimeSpan]::TicksPerSecond) { $t = $t.AddTicks([TimeSpan]::TicksPerSecond - ($t.Ticks % [TimeSpan]::TicksPerSecond)) }
        $when.Add("@SystemTime<='" + $t.ToString('o') + "'")
    }
    if ($when.Count -gt 0) { $sys.Add('TimeCreated[' + ($when -join ' and ') + ']') }
    $query = if ($XPath) { $XPath } elseif ($sys.Count -gt 0) { '*[System[' + ($sys -join ' and ') + ']]' } else { '*' }
    $getMessage = {
        $m = $null
        try { $m = $this.FormatDescription() } catch { }
        if (-not $m) { $m = (@($this.Properties | ForEach-Object { "$($_.Value)" }) -join "`n") }
        $m
    }
    $out = New-Object System.Collections.Generic.List[object]
    $reader = $null
    try {
        $q = New-Object System.Diagnostics.Eventing.Reader.EventLogQuery($LogName, [System.Diagnostics.Eventing.Reader.PathType]::LogName, $query)
        $q.ReverseDirection = -not $Oldest
        $reader = New-Object System.Diagnostics.Eventing.Reader.EventLogReader($q)
        while (($MaxEvents -le 0 -or $out.Count -lt $MaxEvents) -and ($null -ne ($record = $reader.ReadEvent()))) {
            $po = [System.Management.Automation.PSObject]::AsPSObject($record)
            $po.PSObject.Properties.Add((New-Object System.Management.Automation.PSScriptProperty('Message', $getMessage)))
            $out.Add($po)
        }
    } catch {
        if ($ErrorStop) { throw }
    } finally {
        if ($reader) { $reader.Dispose() }
    }
    return $out.ToArray()
}
function Get-DexEventLog {
    param([Parameter(Mandatory = $true)][string]$LogName)
    try { return New-Object System.Diagnostics.Eventing.Reader.EventLogConfiguration($LogName) } catch { return $null }
}
#endregion

function Invoke-AutoRemediateWord {
param(
    [int] $CacheSizeWarningMB      = $(if ($env:CacheSizeWarningMB) { [int]$env:CacheSizeWarningMB } else { 2048 }),
    [bool]$AllowDestructiveActions = $(if ($env:AllowDestructiveActions) { [System.Convert]::ToBoolean($env:AllowDestructiveActions) } else { $false }),
    [int] $CrashWarnCount7d        = $(if ($env:CrashWarnCount7d) { [int]$env:CrashWarnCount7d } else { 3 }),
    [int] $TemplateWarnMB          = $(if ($env:TemplateWarnMB) { [int]$env:TemplateWarnMB } else { 8 }),
    [bool]$ReenableDisabledItems   = $(if ($env:ReenableDisabledItems) { [System.Convert]::ToBoolean($env:ReenableDisabledItems) } else { $false })
)

# -- Product identity (the only product-specific constants) --
$_app      = 'Word'
$_exe      = 'WINWORD.EXE'
$_proc     = 'WINWORD'
$_regApp   = 'Word'
$_officeProcs = @('WINWORD', 'EXCEL', 'POWERPNT', 'OUTLOOK', 'ONENOTE', 'MSACCESS', 'MSPUB', 'MSOSYNC', 'msouc')
# Office's own modules; a fault in one of these is not an add-in's fault.
$_msModule = '^(wwlib|mso\w*|oart\w*|office|msvcr\w*|vcruntime\w*|ucrtbase|ntdll|kernelbase|kernel32|user32|gdi32|combase|ole32|oleaut32|rpcrt4|msvcp\w*|clr|coreclr|mscorwks|riched20|msptls|gfx|d2d1|dwrite|wwintl|mso20win32client|mso30win32client|mso40uiwin32client|mso50win32client|mso98win32client|mso99lwin32client|msointl\w*)\.dll$'
$_msAddin  = '^Microsoft\.|OfficeMicrosoftTeams|Microsoft Online|SharePoint|OneDrive|Skype|Lync|Grammarly\.Microsoft|CopilotAddin'

# -- Pre-flight: Click-to-Run and the exe --
$_c2rConfig = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue
$_c2rRoot   = $null
foreach ($p in @("$env:ProgramFiles\Microsoft Office\root\Office16", "${env:ProgramFiles(x86)}\Microsoft Office\root\Office16")) {
    if (Test-Path (Join-Path $p $_exe)) { $_c2rRoot = $p; break }
}
if (-not $_c2rConfig -or -not $_c2rRoot) {
    Write-Output "`r`n-- Invoke-AutoRemediate$_app -------------------------------------"
    Write-Output "   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Output "   [Skipped] Click-to-Run Microsoft $_app is not installed on this device."
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
$_hku = if ($_userSid) { "Registry::HKEY_USERS\$_userSid" } else { $null }
$_officeVer = '16.0'
if ($_c2rConfig.VersionToReport) {
    $parts = $_c2rConfig.VersionToReport.Split('.')
    if ($parts.Count -ge 2) { $_officeVer = "$($parts[0]).$($parts[1])" }
}
$_noUser = @{ Status = 'Warning'; Message = 'No interactive user resolved -- per-user check skipped.' }

$regPath = "HKLM:\Software\AirWatch\Extension\DEXRecords\${_regApp}Errors"

# -- Cross-step state (filled by step 2, read by 3, 6, 9) --
$script:_crash = @{ Count = 0; Hangs = 0; Module = ''; ModulePath = ''; ThirdParty = $false }
$script:_blame = @()   # step names that found something to blame

function _Expand([string]$s) { if ($s) { [Environment]::ExpandEnvironmentVariables($s) } else { $s } }
function _DirMB([string]$dir) {
    if (-not (Test-Path -LiteralPath $dir)) { return 0 }
    $sum = (Get-ChildItem -LiteralPath $dir -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
    return [math]::Round(($(if ($sum) { $sum } else { 0 })) / 1MB, 1)
}
function _AppOpen { [bool](Get-Process -Name $_proc -ErrorAction SilentlyContinue) }
function _AnyOfficeOpen { [bool](Get-Process -Name $_officeProcs -ErrorAction SilentlyContinue) }
function _Gate { if ($AllowDestructiveActions) { '' } else { ' -- set $AllowDestructiveActions=$true to apply' } }
function _AddinKeys {
    # Every Addins key that can load into this product, user hive first.
    $out = @()
    $subs = @("Software\Microsoft\Office\$_regApp\Addins", "Software\Microsoft\Office\$_officeVer\$_regApp\Addins")
    foreach ($s in $subs) {
        if ($_hku) { $out += "$_hku\$s" }
        $out += "HKLM:\$s"
        $out += "HKLM:\SOFTWARE\WOW6432Node\$($s.Substring(9))"
    }
    return $out | Where-Object { Test-Path $_ }
}
function _ActiveThirdPartyAddins {
    $list = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($k in @(_AddinKeys)) {
        Get-ChildItem $k -ErrorAction SilentlyContinue | ForEach-Object {
            $lb = (Get-ItemProperty $_.PSPath -Name 'LoadBehavior' -ErrorAction SilentlyContinue).LoadBehavior
            if ($lb -eq 3 -and $_.PSChildName -notmatch $_msAddin) {
                $list.Add([PSCustomObject]@{ Name = $_.PSChildName; Path = $_.PSPath; Scope = $(if ($k -like 'Registry::*') { 'user' } else { 'machine' }) })
            }
        }
    }
    return $list
}
function _AddinNamedByCrash($addins) {
    # Match the faulting module's base name against the add-in ProgId tokens.
    if (-not $script:_crash.ThirdParty -or -not $script:_crash.Module) { return $null }
    $token = [IO.Path]::GetFileNameWithoutExtension($script:_crash.Module)
    foreach ($a in $addins) {
        foreach ($part in ($a.Name -split '[.\s_-]')) {
            if ($part.Length -ge 4 -and ($token -like "*$part*" -or $part -like "*$token*")) { return $a }
        }
    }
    return $null
}
function _DecodeResiliency([string]$key) {
    # Each value is a binary blob with the item's display name and path in UTF-16.
    $names = @()
    if (-not (Test-Path $key)) { return $names }
    $item = Get-Item $key -ErrorAction SilentlyContinue
    foreach ($v in $item.GetValueNames()) {
        $bytes = $item.GetValue($v)
        if ($bytes -is [byte[]]) {
            $text = [Text.Encoding]::Unicode.GetString($bytes)
            $segs = @($text -split "`0" | Where-Object { $_ -match '[A-Za-z]{3,}' })
            $names += $(if ($segs.Count -gt 0) { $segs[0].Trim() } else { $v })
        } else { $names += $v }
    }
    return $names
}

# -- Step Definitions --
$Steps = @(

    @{
        Name             = 'Crash and Hang History'
        Order            = 2
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            # Server-side filter only: an unfiltered Application log read runs 100+ s.
            $since = (Get-Date).AddDays(-7)
            $ev = @()
            try {
                $ev = @(Get-DexEvent -LogName 'Application' -ProviderName 'Application Error', 'Application Hang' -Id 1000, 1002 -StartTime $since |
                        Where-Object { $_.Properties.Count -gt 0 -and "$($_.Properties[0].Value)" -ieq $_exe })
            } catch {
                return @{ Status = 'Warning'; Message = "Unable to query the Application log: $($_.Exception.Message)" }
            }
            if ($ev.Count -eq 0) {
                return @{ Status = 'Passed'; Message = "No $_exe crash (1000) or hang (1002) events in the last 7 days." }
            }
            $crashes = @($ev | Where-Object { $_.Id -eq 1000 })
            $hangs   = @($ev | Where-Object { $_.Id -eq 1002 })
            $script:_crash.Count = $ev.Count
            $script:_crash.Hangs = $hangs.Count
            $last = $crashes | Sort-Object TimeCreated -Descending | Select-Object -First 1
            $mod = ''; $modPath = ''
            if ($last) {
                if ($last.Properties.Count -gt 3)  { $mod     = "$($last.Properties[3].Value)" }
                if ($last.Properties.Count -gt 11) { $modPath = "$($last.Properties[11].Value)" }
                if (-not $mod -and $last.Message -match 'Faulting module name:\s*([^,\r\n]+)') { $mod = $Matches[1].Trim() }
                $script:_crash.Module     = $mod
                $script:_crash.ModulePath = $modPath
                $script:_crash.ThirdParty = ($mod -and $mod -notmatch $_msModule -and $modPath -notmatch '\\Microsoft Office\\root\\|\\Windows\\(System32|SysWOW64)\\')
            }
            $detail = "$($crashes.Count) crash(es), $($hangs.Count) hang(s) in 7 days"
            if ($mod) { $detail += "; last faulting module $mod$(if ($modPath) { " ($modPath)" })$(if ($script:_crash.ThirdParty) { ' -- not an Office module, likely an add-in' })" }
            if ($ev.Count -ge $CrashWarnCount7d) {
                return @{ Status = 'Failed'; Message = "$detail (threshold $CrashWarnCount7d). Steps 3, 6 and 9 use this." }
            }
            return @{ Status = 'Warning'; Message = "$detail (threshold $CrashWarnCount7d)." }
        }
        ResolutionScript = $null
    },

    @{
        Name             = 'COM Add-in Conflict'
        Order            = 3
        Enabled          = $true
        ResolveOnWarning = $AllowDestructiveActions
        DetectionScript  = {
            $addins = @(_ActiveThirdPartyAddins)
            if ($addins.Count -eq 0) {
                return @{ Status = 'Passed'; Message = "No active third-party $_app add-ins (user and machine hives)." }
            }
            $named = _AddinNamedByCrash $addins
            $names = ($addins | ForEach-Object { "$($_.Name) [$($_.Scope)]" }) -join ', '
            if ($named) {
                $script:_blame += 'add-in'
                return @{ Status = 'Failed'; Message = "Crash module $($script:_crash.Module) matches add-in '$($named.Name)'; $($addins.Count) active third-party add-in(s): $names. Will set LoadBehavior=0 on '$($named.Name)'$(_Gate)." }
            }
            if ($script:_crash.ThirdParty) { $script:_blame += 'add-in' }
            return @{ Status = 'Warning'; Message = "$($addins.Count) active third-party add-in(s): $names. Disabling the first one is the remediation$(_Gate)." }
        }
        ResolutionScript = {
            $addins = @(_ActiveThirdPartyAddins)
            if ($addins.Count -eq 0) { return @{ Remediated = $false } }
            $target = _AddinNamedByCrash $addins
            if (-not $target) { $target = $addins[0] }
            Set-ItemProperty -Path $target.Path -Name 'LoadBehavior' -Value 0 -ErrorAction Stop
            return @{ Remediated = $true; Message = "Add-in '$($target.Name)' [$($target.Scope)] set to LoadBehavior=0. Restart $_app to take effect." }
        }
    },

    @{
        Name             = 'Office-Disabled Items'
        Order            = 4
        Enabled          = $true
        ResolveOnWarning = $ReenableDisabledItems
        DetectionScript  = {
            if (-not $_hku) { return $_noUser }
            $base = "$_hku\Software\Microsoft\Office\$_officeVer\$_regApp\Resiliency"
            $disabled = @(_DecodeResiliency "$base\DisabledItems")
            $startup  = @(_DecodeResiliency "$base\StartupItems")
            if ($disabled.Count -eq 0 -and $startup.Count -eq 0) {
                return @{ Status = 'Passed'; Message = "$_app has not disabled any add-ins or startup items." }
            }
            $script:_blame += 'disabled-items'
            $all = @($disabled + $startup | Select-Object -First 6) -join ', '
            $gate = if ($ReenableDisabledItems) { 'Clearing the entries so they load next launch.' } else { 'Set $ReenableDisabledItems=$true to clear them; Office disabled these after a failure, so confirm first.' }
            return @{ Status = 'Warning'; Message = "$($disabled.Count) disabled item(s), $($startup.Count) disabled startup item(s): $all. $gate" }
        }
        ResolutionScript = {
            $base = "$_hku\Software\Microsoft\Office\$_officeVer\$_regApp\Resiliency"
            $n = 0
            foreach ($sub in 'DisabledItems', 'StartupItems') {
                $k = "$base\$sub"
                if (-not (Test-Path $k)) { continue }
                foreach ($v in (Get-Item $k).GetValueNames()) { Remove-ItemProperty -Path $k -Name $v -ErrorAction Stop; $n++ }
            }
            return @{ Remediated = ($n -gt 0); Message = "Cleared $n Resiliency entr$(if ($n -eq 1) { 'y' } else { 'ies' }); items load at $_app's next start." }
        }
    },

    @{
        Name             = 'AutoRecover Location'
        Order            = 5
        Enabled          = $true
        ResolveOnWarning = $true
        DetectionScript  = {
            if (-not $_hku -or -not $_userProfile) { return $_noUser }
            $opt = Get-ItemProperty "$_hku\Software\Microsoft\Office\$_officeVer\$_regApp\Options" -ErrorAction SilentlyContinue
            $raw = if ($opt -and $opt.PSObject.Properties['AUTOSAVE-PATH']) { "$($opt.'AUTOSAVE-PATH')" } else { '' }
            if (-not $raw) {
                return @{ Status = 'Passed'; Message = 'AutoRecover uses the default location.' }
            }
            $path = _Expand $raw
            if (Test-Path -LiteralPath $path) {
                return @{ Status = 'Passed'; Message = "AutoRecover path exists: $path" }
            }
            return @{ Status = 'Warning'; Message = "AutoRecover path does not exist: $path. Creating it so recovery files have somewhere to go." }
        }
        ResolutionScript = {
            $opt  = Get-ItemProperty "$_hku\Software\Microsoft\Office\$_officeVer\$_regApp\Options" -ErrorAction SilentlyContinue
            $path = _Expand "$($opt.'AUTOSAVE-PATH')"
            if (-not $path) { return @{ Remediated = $false } }
            New-Item -ItemType Directory -Path $path -Force -ErrorAction Stop | Out-Null
            return @{ Remediated = $true; Message = "Created AutoRecover folder $path." }
        }
    },

    @{
        Name             = 'Normal.dotm Health'
        Order            = 6
        Enabled          = $true
        ResolveOnWarning = $AllowDestructiveActions
        DetectionScript  = {
            if (-not $_userProfile) { return $_noUser }
            $tpl = Join-Path $_userProfile 'AppData\Roaming\Microsoft\Templates\Normal.dotm'
            if (-not (Test-Path -LiteralPath $tpl)) {
                return @{ Status = 'Passed'; Message = "No Normal.dotm yet; $_app creates it on first use." }
            }
            $f  = Get-Item -LiteralPath $tpl
            $mb = [math]::Round($f.Length / 1MB, 2)
            $suspect = ($script:_crash.Count -ge $CrashWarnCount7d -and $script:_crash.Module -ieq 'wwlib.dll' -and -not $script:_crash.ThirdParty -and $script:_blame.Count -eq 0)
            if ($mb -lt $TemplateWarnMB -and -not $suspect) {
                return @{ Status = 'Passed'; Message = "Normal.dotm is ${mb}MB (threshold ${TemplateWarnMB}MB), modified $($f.LastWriteTime.ToString('yyyy-MM-dd'))." }
            }
            $script:_blame += 'template'
            $why = if ($mb -ge $TemplateWarnMB) { "is ${mb}MB (threshold ${TemplateWarnMB}MB)" } else { "is ${mb}MB but repeated wwlib.dll crashes with no add-in blamed point at it" }
            $open = if (_AppOpen) { " $_app is open, so the rename waits for a run with $_app closed." } else { '' }
            return @{ Status = 'Warning'; Message = "Normal.dotm $why. Rename to Normal_<stamp>.dotm.bak so $_app rebuilds it; user macros and styles stay in the backup$(_Gate).$open" }
        }
        ResolutionScript = {
            if (_AppOpen) { return @{ Remediated = $false; Status = 'Warning'; Message = "Normal.dotm rename skipped: $_app is open. Re-run with $_app closed." } }
            $tpl = Join-Path $_userProfile 'AppData\Roaming\Microsoft\Templates\Normal.dotm'
            $new = "Normal_$(Get-Date -Format 'yyyyMMdd-HHmmss').dotm.bak"
            Rename-Item -LiteralPath $tpl -NewName $new -ErrorAction Stop
            return @{ Remediated = $true; Message = "Normal.dotm renamed to $new; $_app rebuilds a clean template on next launch." }
        }
    },

    @{
        Name             = 'Office Document Cache'
        Order            = 7
        Enabled          = $true    # suite-wide: enabled only in the Word script
        ResolveOnWarning = $AllowDestructiveActions
        DetectionScript  = {
            if (-not $_userProfile) { return $_noUser }
            $dir = Join-Path $_userProfile "AppData\Local\Microsoft\Office\$_officeVer\OfficeFileCache"
            if (-not (Test-Path -LiteralPath $dir)) {
                return @{ Status = 'Passed'; Message = 'No Office Document Cache folder (nothing cached yet).' }
            }
            $mb    = _DirMB $dir
            $files = @(Get-ChildItem -LiteralPath $dir -File -Force -ErrorAction SilentlyContinue)
            $table = Get-Item -LiteralPath (Join-Path $dir 'CentralTable.accdb') -ErrorAction SilentlyContinue
            $corrupt = ($files.Count -gt 0 -and (-not $table -or $table.Length -eq 0))
            if ($mb -lt $CacheSizeWarningMB -and -not $corrupt) {
                return @{ Status = 'Passed'; Message = "Office Document Cache is ${mb}MB (threshold ${CacheSizeWarningMB}MB), $($files.Count) file(s)." }
            }
            $why  = if ($corrupt) { 'CentralTable.accdb is missing or empty while the cache has content' } else { "is ${mb}MB (threshold ${CacheSizeWarningMB}MB)" }
            $open = if (_AnyOfficeOpen) { ' An Office app is open; the rename waits for a run with Office closed (unsynced uploads live here).' } else { '' }
            return @{ Status = 'Warning'; Message = "Office Document Cache $why. Rename to OfficeFileCache_<stamp>.bak; Office rebuilds it$(_Gate).$open" }
        }
        ResolutionScript = {
            if (_AnyOfficeOpen) { return @{ Remediated = $false; Status = 'Warning'; Message = 'Office Document Cache rename skipped: an Office app is open. Re-run with Office closed.' } }
            $dir = Join-Path $_userProfile "AppData\Local\Microsoft\Office\$_officeVer\OfficeFileCache"
            $new = "OfficeFileCache_$(Get-Date -Format 'yyyyMMdd-HHmmss').bak"
            Rename-Item -LiteralPath $dir -NewName $new -ErrorAction Stop
            return @{ Remediated = $true; Message = "Office Document Cache renamed to $new; Office rebuilds it on next launch." }
        }
    },

    @{
        Name             = 'Office C2R Update Health'
        Order            = 8
        Enabled          = $true    # suite-wide: enabled only in the Word script
        ResolveOnWarning = $false
        DetectionScript  = {
            $version = $_c2rConfig.VersionToReport
            if ($_c2rConfig.UpdatesEnabled -eq 'False') {
                return @{ Status = 'Warning'; Message = "C2R updates are disabled (UpdatesEnabled=False). Version: $version. Updates are managed by policy or MDM -- no remediation attempted." }
            }
            $u = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Updates' -ErrorAction SilentlyContinue
            if ($u -and $u.ErrorCode -and $u.ErrorCode -ne 0) {
                return @{ Status = 'Warning'; Message = "C2R update last failed with error $('0x{0:X8}' -f $u.ErrorCode). Version: $version. Updates are MDM-managed; reported only." }
            }
            if (-not $_c2rConfig.CDNBaseUrl) {
                return @{ Status = 'Warning'; Message = "C2R update channel (CDNBaseUrl) not configured. Version: $version." }
            }
            return @{ Status = 'Passed'; Message = "C2R updates enabled. Version: $version." }
        }
        ResolutionScript = $null
    },

    @{
        Name             = 'Word Data Key'
        Order            = 9
        Enabled          = $true
        ResolveOnWarning = $AllowDestructiveActions
        DetectionScript  = {
            if (-not $_hku) { return $_noUser }
            $key = "$_hku\Software\Microsoft\Office\$_officeVer\Word\Data"
            if ($script:_crash.Count -lt $CrashWarnCount7d) {
                return @{ Status = 'Passed'; Message = 'Not indicated: crash count is under threshold.' }
            }
            if ($script:_blame.Count -gt 0) {
                return @{ Status = 'Passed'; Message = "Not indicated: step(s) $($script:_blame -join ', ') already found a cause." }
            }
            if (-not (Test-Path $key)) {
                return @{ Status = 'Passed'; Message = 'Word Data key absent; nothing to reset.' }
            }
            $open = if (_AppOpen) { " $_app is open, so the reset waits for a run with $_app closed." } else { '' }
            return @{ Status = 'Warning'; Message = "Repeated crashes with no add-in, disabled item or template to blame. Resetting the Word Data key (rename to Data_<stamp>) clears corrupted option state; recent-file list is lost$(_Gate).$open" }
        }
        ResolutionScript = {
            if (_AppOpen) { return @{ Remediated = $false; Status = 'Warning'; Message = "Word Data key reset skipped: $_app is open. Re-run with $_app closed." } }
            $key = "$_hku\Software\Microsoft\Office\$_officeVer\Word\Data"
            $new = "Data_$(Get-Date -Format 'yyyyMMdd-HHmmss')"
            Rename-Item -Path $key -NewName $new -ErrorAction Stop
            return @{ Remediated = $true; Message = "Word Data key renamed to $new; $_app rebuilds it on next launch." }
        }
    },

    @{
        Name             = 'Startup Folder'
        Order            = 10
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            $dirs = @(Join-Path $_c2rRoot 'STARTUP')
            if ($_userProfile) { $dirs += Join-Path $_userProfile 'AppData\Roaming\Microsoft\Word\STARTUP' }
            $files = @()
            foreach ($d in $dirs) {
                if (Test-Path -LiteralPath $d) { $files += @(Get-ChildItem -LiteralPath $d -File -Force -ErrorAction SilentlyContinue) }
            }
            if ($files.Count -eq 0) {
                return @{ Status = 'Passed'; Message = 'No files in the user or machine Word STARTUP folders.' }
            }
            $names = ($files | Select-Object -First 5 | ForEach-Object { "$($_.Name) ($([math]::Round($_.Length / 1KB))KB)" }) -join ', '
            return @{ Status = 'Warning'; Message = "$($files.Count) file(s) load at every $_app start: $names. Report only; startup add-ins are deployed on purpose, but a corrupt one crashes $_app at launch." }
        }
        ResolutionScript = $null
    }
)

# -- Execution Engine --
$activeSteps = @($Steps | Where-Object { $_.Enabled } | Sort-Object { [int]$_.Order })
$results     = [System.Collections.Generic.List[PSCustomObject]]::new()

Write-Output "`r`n-- Invoke-AutoRemediate$_app -------------------------------------"
Write-Output "   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')   Steps: $($activeSteps.Count)   User: $(if ($_loggedOnUser) { $_loggedOnUser } else { 'unknown' })   Office $($_c2rConfig.VersionToReport)"
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
    Set-ItemProperty -Path $regPath -Name 'ScriptVersion'   -Value '1.0.1'       -Type String
    Set-ItemProperty -Path $regPath -Name 'TotalSteps'      -Value $results.Count -Type DWord
    Set-ItemProperty -Path $regPath -Name 'PassedCount'     -Value $passed        -Type DWord
    Set-ItemProperty -Path $regPath -Name 'WarningCount'    -Value $warnings      -Type DWord
    Set-ItemProperty -Path $regPath -Name 'FailedCount'     -Value $failed        -Type DWord
    Set-ItemProperty -Path $regPath -Name 'RemediatedCount' -Value $remCount      -Type DWord
    Set-ItemProperty -Path $regPath -Name 'CrashCount7d'    -Value $script:_crash.Count -Type DWord
    if ($script:_crash.Module) { Set-ItemProperty -Path $regPath -Name 'LastFaultModule' -Value $script:_crash.Module -Type String }

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

Invoke-AutoRemediateWord
Exit 0
