<#
.SYNOPSIS
    Invoke-AutoRemediateExcel -- Automated Microsoft Excel diagnostic and remediation.

.DESCRIPTION
    Sequenced Excel health checks with remediation where safe. Self-contained; built for
    Workspace ONE remediation or standalone use. Network, disk, memory and Windows
    Update belong to the generic scripts -- run those first.

    | Step | Name                         | Remediates On                       |
    |  2   | Crash and Hang History       | -- (report only; feeds 3, 6)        |
    |  3   | COM Add-in Conflict          | Warning/Failed ($AllowDestructive)  |
    |  4   | Office-Disabled Items        | Warning ($ReenableDisabledItems)    |
    |  5   | AutoRecover Settings         | Warning                             |
    |  6   | XLSTART Content              | Warning/Failed ($AllowDestructive)  |
    |  7   | Office Document Cache        | DISABLED (Word owns it)             |
    |  8   | Office C2R Update Health     | DISABLED (Word owns it)             |
    |  9   | XLAM Add-in Registration     | Warning (dangling entries only)     |
    | 10   | Calculation Options          | -- (report only)                    |

    Pre-flight: no EXCEL.EXE under the Click-to-Run root = "not installed", exit 0.
    Steps 2-8 are the common Office steps (spec C2-C8); same engine as the Word script.
    Steps 7 and 8 are suite-wide and ship Enabled = $false here -- flip them only on an
    estate that deploys Excel without Word. One script per product until UEM has
    dynamic variables.

    Step 6 covers the user and machine XLSTART folders plus Options\AltStartup; every
    file there opens on every launch, so with repeated crashes it goes Failed. The
    quarantine moves all but PERSONAL.XLSB to XLSTART_quarantine_<stamp> beside the
    folder (machine folder included: the spec treats stray startup content as the
    fault). Step 9 drops OPENn registrations whose file is gone and renumbers. Excel
    rewrites Options on exit, so registry fixes wait for a run with Excel closed.

    SYSTEM context: profile and hive come from Win32_ComputerSystem.UserName and
    HKU\<SID>, never $env:APPDATA. No interactive user: per-user steps Warn "skipped".

.PARAMETER CacheSizeWarningMB
    Step 7 threshold in MB (disabled here). Default 2048.
.PARAMETER AllowDestructiveActions
    Enables steps 3 and 6. Default $false.
.PARAMETER CrashWarnCount7d
    Crash plus hang count in 7 days that turns step 2 Failed. Default 3.
.PARAMETER TemplateWarnMB
    Unused here; kept for family parity. Default 8.
.PARAMETER ReenableDisabledItems
    Lets step 4 clear Office's Resiliency entries. Default $false.
    Every input also reads $env:<name>.

.NOTES
    Script Name  : Invoke-AutoRemediateExcel.ps1
    Version      : 1.0.1
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-05 (1.0.1: crash and hang events read through the .NET EventLogReader; Get-WinEvent fails in every form under Hub's ARM64 PowerShell 7.2 engine; 1.0.0: first build from App_Remediation_Specs.md section 9)
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

function Invoke-AutoRemediateExcel {
param(
    [int] $CacheSizeWarningMB      = $(if ($env:CacheSizeWarningMB) { [int]$env:CacheSizeWarningMB } else { 2048 }),
    [bool]$AllowDestructiveActions = $(if ($env:AllowDestructiveActions) { [System.Convert]::ToBoolean($env:AllowDestructiveActions) } else { $false }),
    [int] $CrashWarnCount7d        = $(if ($env:CrashWarnCount7d) { [int]$env:CrashWarnCount7d } else { 3 }),
    [int] $TemplateWarnMB          = $(if ($env:TemplateWarnMB) { [int]$env:TemplateWarnMB } else { 8 }),
    [bool]$ReenableDisabledItems   = $(if ($env:ReenableDisabledItems) { [System.Convert]::ToBoolean($env:ReenableDisabledItems) } else { $false })
)

# -- Product identity (the only product-specific constants) --
$_app      = 'Excel'
$_exe      = 'EXCEL.EXE'
$_proc     = 'EXCEL'
$_regApp   = 'Excel'
$_officeProcs = @('WINWORD', 'EXCEL', 'POWERPNT', 'OUTLOOK', 'ONENOTE', 'MSACCESS', 'MSPUB', 'MSOSYNC', 'msouc')
# Office's own modules; a fault in one of these is not an add-in's fault.
$_msModule = '^(excel|xl\w*|wwlib|mso\w*|oart\w*|office|msvc\w*|vcruntime\w*|ucrtbase|ntdll|kernel\w*|user32|gdi32|combase|ole\w*|rpcrt4|clr|coreclr|riched20|msptls|gfx|d2d1|dwrite)\.(dll|exe)$'
$_msAddin  = '^Microsoft\.|OfficeMicrosoftTeams|Microsoft Online|SharePoint|OneDrive|Skype|Lync|Grammarly\.Microsoft|CopilotAddin|PowerPivot|PowerMap|Inquire|NativeShim'

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
$_noUser  = @{ Status = 'Warning'; Message = 'No interactive user resolved -- per-user check skipped.' }
$_optKey  = if ($_hku) { "$_hku\Software\Microsoft\Office\$_officeVer\$_regApp\Options" } else { $null }

$regPath = "HKLM:\Software\AirWatch\Extension\DEXRecords\${_regApp}Errors"

# -- Cross-step state (filled by step 2, read by 3 and 6) --
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
function _Opts { if ($_optKey) { Get-ItemProperty $_optKey -ErrorAction SilentlyContinue } }
function _AddinKeys {
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
function _XlStartFiles {
    $list = [System.Collections.Generic.List[PSCustomObject]]::new()
    $dirs = @()
    if ($_userProfile) { $dirs += [PSCustomObject]@{ Dir = (Join-Path $_userProfile 'AppData\Roaming\Microsoft\Excel\XLSTART'); Scope = 'user' } }
    $dirs += [PSCustomObject]@{ Dir = (Join-Path $_c2rRoot 'XLSTART'); Scope = 'machine' }
    $alt = (_Opts).AltStartup
    if ($alt) { $dirs += [PSCustomObject]@{ Dir = (_Expand "$alt"); Scope = 'alt' } }
    foreach ($d in $dirs) {
        if (-not (Test-Path -LiteralPath $d.Dir)) { continue }
        Get-ChildItem -LiteralPath $d.Dir -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ine 'PERSONAL.XLSB' } | ForEach-Object {
            $list.Add([PSCustomObject]@{ File = $_; Scope = $d.Scope })
        }
    }
    return $list
}
function _XlamRegs {
    $list = [System.Collections.Generic.List[PSCustomObject]]::new()
    $opt = _Opts
    if (-not $opt) { return $list }
    $opt.PSObject.Properties | Where-Object { $_.Name -match '^OPEN(\d*)$' } |
        Sort-Object { [int]('0' + ($_.Name -replace '^OPEN', '')) } | ForEach-Object {
            $raw  = "$($_.Value)"
            $path = _Expand (($raw -replace '^(\s*/\w+\s+)+', '').Trim().Trim('"'))
            $list.Add([PSCustomObject]@{ Name = $_.Name; Raw = $raw; Path = $path; Exists = [bool]($path -and (Test-Path -LiteralPath $path)) })
        }
    return $list
}

# -- Step Definitions --
$Steps = @(

    @{
        Name             = 'Crash and Hang History'
        Order            = 2
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
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
                return @{ Status = 'Failed'; Message = "$detail (threshold $CrashWarnCount7d). Steps 3 and 6 use this." }
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
        Name             = 'AutoRecover Settings'
        Order            = 5
        Enabled          = $true
        ResolveOnWarning = $true
        DetectionScript  = {
            if (-not $_hku -or -not $_userProfile) { return $_noUser }
            $opt = _Opts
            $off  = ($opt -and $opt.PSObject.Properties['AutoRecoverEnabled'] -and [int]$opt.AutoRecoverEnabled -eq 0)
            $raw  = if ($opt -and $opt.PSObject.Properties['AutoRecoverPath']) { "$($opt.AutoRecoverPath)" } else { '' }
            $path = _Expand $raw
            $missing = ($path -and -not (Test-Path -LiteralPath $path))
            if (-not $off -and -not $missing) {
                return @{ Status = 'Passed'; Message = $(if ($path) { "AutoRecover is on; path exists: $path" } else { 'AutoRecover is on and uses the default location.' }) }
            }
            $why = @(); if ($off) { $why += 'AutoRecoverEnabled=0 (recovery files are not written)' }; if ($missing) { $why += "AutoRecoverPath does not exist: $path" }
            $open = if ($off -and (_AppOpen)) { " $_app is open and rewrites Options on exit, so the re-enable waits for a run with $_app closed." } else { '' }
            return @{ Status = 'Warning'; Message = "$($why -join '; '). Re-enabling and creating the folder so recovery files have somewhere to go.$open" }
        }
        ResolutionScript = {
            $opt  = _Opts
            $did  = @()
            $path = _Expand "$($opt.AutoRecoverPath)"
            if ($path -and -not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Path $path -Force -ErrorAction Stop | Out-Null; $did += "created $path" }
            if ($opt.PSObject.Properties['AutoRecoverEnabled'] -and [int]$opt.AutoRecoverEnabled -eq 0) {
                if (_AppOpen) { return @{ Remediated = ($did.Count -gt 0); Status = 'Warning'; Message = "AutoRecoverEnabled left at 0: $_app is open. Re-run with $_app closed.$(if ($did) { ' Folder ' + ($did -join ', ') })" } }
                Set-ItemProperty -Path $_optKey -Name 'AutoRecoverEnabled' -Value 1 -Type DWord -ErrorAction Stop; $did += 'set AutoRecoverEnabled=1'
            }
            return @{ Remediated = ($did.Count -gt 0); Message = "AutoRecover: $($did -join '; ')." }
        }
    },

    @{
        Name             = 'XLSTART Content'
        Order            = 6
        Enabled          = $true
        ResolveOnWarning = $AllowDestructiveActions
        DetectionScript  = {
            $items = @(_XlStartFiles)
            if ($items.Count -eq 0) {
                return @{ Status = 'Passed'; Message = 'No startup content beyond PERSONAL.XLSB in the user, machine or AltStartup XLSTART folders.' }
            }
            $script:_blame += 'startup-content'
            $names = ($items | Select-Object -First 5 | ForEach-Object { "$($_.File.Name) ($([math]::Round($_.File.Length / 1KB))KB) [$($_.Scope)]" }) -join ', '
            $open  = if (_AppOpen) { " $_app is open, so the move waits for a run with $_app closed." } else { '' }
            $msg   = "$($items.Count) file(s) open at every $_app launch: $names. A corrupt one crashes $_app at start. Move to XLSTART_quarantine_<stamp> beside the folder$(_Gate).$open"
            if ($script:_crash.Count -ge $CrashWarnCount7d) {
                return @{ Status = 'Failed'; Message = "Repeated crashes and $msg" }
            }
            return @{ Status = 'Warning'; Message = $msg }
        }
        ResolutionScript = {
            if (_AppOpen) { return @{ Remediated = $false; Status = 'Warning'; Message = "XLSTART quarantine skipped: $_app is open. Re-run with $_app closed." } }
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            $moved = 0; $dests = @()
            foreach ($i in @(_XlStartFiles)) {
                $q = Join-Path (Split-Path -Parent $i.File.DirectoryName) "XLSTART_quarantine_$stamp"
                if (-not (Test-Path -LiteralPath $q)) { New-Item -ItemType Directory -Path $q -Force -ErrorAction Stop | Out-Null; $dests += $q }
                Move-Item -LiteralPath $i.File.FullName -Destination $q -ErrorAction Stop
                $moved++
            }
            return @{ Remediated = ($moved -gt 0); Message = "Moved $moved startup file(s) to $($dests -join '; '). $_app launches clean; restore from there if one was wanted." }
        }
    },

    @{
        Name             = 'Office Document Cache'
        Order            = 7
        Enabled          = $false   # suite-wide: enabled only in the Word script
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
        Enabled          = $false   # suite-wide: enabled only in the Word script
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
        Name             = 'XLAM Add-in Registration'
        Order            = 9
        Enabled          = $true
        ResolveOnWarning = $true
        DetectionScript  = {
            if (-not $_hku) { return $_noUser }
            $regs = @(_XlamRegs)
            if ($regs.Count -eq 0) {
                return @{ Status = 'Passed'; Message = 'No OPENn add-in registrations in Excel Options.' }
            }
            $gone = @($regs | Where-Object { -not $_.Exists })
            if ($gone.Count -eq 0) {
                return @{ Status = 'Passed'; Message = "$($regs.Count) OPENn add-in registration(s), all files present." }
            }
            $names = ($gone | Select-Object -First 4 | ForEach-Object { "$($_.Name)=$($_.Path)" }) -join ', '
            $open  = if (_AppOpen) { " $_app is open and rewrites Options on exit, so the cleanup waits for a run with $_app closed." } else { '' }
            return @{ Status = 'Warning'; Message = "$($gone.Count) of $($regs.Count) OPENn registration(s) point at a missing .xla/.xlam: $names. $_app warns about each at launch. Removing the dangling entries and renumbering.$open" }
        }
        ResolutionScript = {
            if (_AppOpen) { return @{ Remediated = $false; Status = 'Warning'; Message = "OPENn cleanup skipped: $_app is open. Re-run with $_app closed." } }
            $regs = @(_XlamRegs)
            $keep = @($regs | Where-Object { $_.Exists })
            foreach ($r in $regs) { Remove-ItemProperty -Path $_optKey -Name $r.Name -ErrorAction Stop }
            for ($i = 0; $i -lt $keep.Count; $i++) {
                $name = if ($i -eq 0) { 'OPEN' } else { "OPEN$i" }
                Set-ItemProperty -Path $_optKey -Name $name -Value $keep[$i].Raw -Type String -ErrorAction Stop
            }
            $kept = switch ($keep.Count) { 0 { 'none kept' } 1 { '1 kept as OPEN' } default { "$($keep.Count) kept, renumbered OPEN..OPEN$($keep.Count - 1)" } }
            return @{ Remediated = $true; Message = "Removed $($regs.Count - $keep.Count) dangling registration(s); $kept." }
        }
    },

    @{
        Name             = 'Calculation Options'
        Order            = 10
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            if (-not $_hku) { return $_noUser }
            $opt = _Opts
            if (-not $opt -or -not $opt.PSObject.Properties['DefaultCalcMode']) {
                return @{ Status = 'Passed'; Message = 'No calculation-mode override in Excel Options; the mode comes from the first workbook opened.' }
            }
            $v = [int]$opt.DefaultCalcMode
            if ($v -eq 1 -or $v -eq -4105) {
                return @{ Status = 'Passed'; Message = "DefaultCalcMode=$v (automatic)." }
            }
            return @{ Status = 'Warning'; Message = "DefaultCalcMode=$v is not automatic. Formulas will not update until F9; report only, manual calculation is often deliberate on large models." }
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

    $results.Add([PSCustomObject]@{ Order = $step.Order; Name = $step.Name; Status = $status; Message = $message; Remediated = $remediated; RemError = $remError })
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
    (Get-Item -Path $regPath).GetValueNames() | ForEach-Object { Remove-ItemProperty -Path $regPath -Name $_ -ErrorAction SilentlyContinue }
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

Invoke-AutoRemediateExcel
Exit 0
