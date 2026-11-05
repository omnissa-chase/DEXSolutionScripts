<#
.SYNOPSIS
    Invoke-AutoRemediatePowerPoint -- Automated Microsoft PowerPoint diagnostic and remediation.

.DESCRIPTION
    Sequenced PowerPoint health checks with remediation where safe. Self-contained; built
    for Workspace ONE remediation or standalone use. Network, disk, memory and Windows
    Update belong to the generic scripts -- run those first.

    | Step | Name                         | Remediates On                       |
    |  2   | Crash and Hang History       | -- (report only; feeds 6)           |
    |  5   | AutoRecover Settings         | Warning                             |
    |  6   | Graphics Acceleration Fault  | Warning ($AllowDestructive)         |
    |  7   | Office Document Cache        | DISABLED (Word owns it)             |
    |  8   | Office C2R Update Health     | DISABLED (Word owns it)             |
    | 10   | Blank Template Health        | Warning ($AllowDestructive)         |

    Pre-flight: no POWERPNT.EXE under the Click-to-Run root = "not installed", exit 0.
    Common Office steps (spec C2-C8), same engine as the Word script. Steps 3 (COM
    Add-in Conflict) and 4 (Office-Disabled Items) moved to ApplicationSpecific\
    Microsoft\Office\Invoke-AutoRemediateOfficeAddins.ps1, which covers all six Office
    applications in one run; their numbers stay as gaps so DEXRecords names hold. Steps
    7 and 8 are suite-wide and ship Enabled = $false here -- flip them only on an estate
    that deploys PowerPoint without Word. Spec step 9 (presenter view and display
    config) has nothing to fix locally and is omitted. One script per product until UEM
    has dynamic variables.

    Step 6 fires when the last crash faulted in a display-driver module (ig*, nv*,
    atidx*, amd*, d3d*, dxgi) or in oart.dll (Office drawing layer). The fix sets
    Common\Graphics\DisableHardwareAcceleration=1 in the user's hive, which affects
    every Office app, so it is gated and the message says so. Step 10 renames an
    oversized Blank.potx the way Word handles Normal.dotm.

    SYSTEM context: profile and hive come from Win32_ComputerSystem.UserName and
    HKU\<SID>, never $env:APPDATA. No interactive user: per-user steps Warn "skipped".

.PARAMETER CacheSizeWarningMB
    Step 7 threshold in MB (disabled here). Default 2048.
.PARAMETER AllowDestructiveActions
    Enables steps 6 and 10. Default $false.
.PARAMETER CrashWarnCount7d
    Crash plus hang count in 7 days that turns step 2 Failed. Default 3.
.PARAMETER TemplateWarnMB
    Blank.potx size that turns step 10 Warning. Default 8. Every input also reads $env:<name>.

.NOTES
    Script Name  : Invoke-AutoRemediatePowerPoint.ps1
    Version      : 1.0.3
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-05 (1.0.3: the COM Add-in Conflict and Office-Disabled Items steps moved to
                   ApplicationSpecific\Microsoft\Office\Invoke-AutoRemediateOfficeAddins.ps1, which covers
                   all six Office applications in one run; step numbering kept (3 and 4 are now gaps); the
                   ReenableDisabledItems input moved with them. 1.0.2: step 3 returns Warning, not Failed, when a crash names
                   an add-in while AllowDestructiveActions is off, so the gate its message
                   promises holds; the engine remediates every Failed. 1.0.1: crash and hang events read through the .NET EventLogReader; Get-WinEvent fails in every form under Hub's ARM64 PowerShell 7.2 engine; 1.0.0: first build from App_Remediation_Specs.md section 10)
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

function Invoke-AutoRemediatePowerPoint {
param(
    [int] $CacheSizeWarningMB      = $(if ($env:CacheSizeWarningMB) { [int]$env:CacheSizeWarningMB } else { 2048 }),
    [bool]$AllowDestructiveActions = $(if ($env:AllowDestructiveActions) { [System.Convert]::ToBoolean($env:AllowDestructiveActions) } else { $false }),
    [int] $CrashWarnCount7d        = $(if ($env:CrashWarnCount7d) { [int]$env:CrashWarnCount7d } else { 3 }),
    [int] $TemplateWarnMB          = $(if ($env:TemplateWarnMB) { [int]$env:TemplateWarnMB } else { 8 })
)

# -- Product identity (the only product-specific constants) --
$_app      = 'PowerPoint'
$_exe      = 'POWERPNT.EXE'
$_proc     = 'POWERPNT'
$_regApp   = 'PowerPoint'
$_officeProcs = @('WINWORD', 'EXCEL', 'POWERPNT', 'OUTLOOK', 'ONENOTE', 'MSACCESS', 'MSPUB', 'MSOSYNC', 'msouc')
# Office's own modules; a fault in one of these is not an add-in's fault.
$_msModule = '^(powerpnt|ppcore|ppintl\w*|wwlib|mso\w*|oart\w*|office|msvc\w*|vcruntime\w*|ucrtbase|ntdll|kernel\w*|user32|gdi32|combase|ole\w*|rpcrt4|clr|coreclr|riched20|msptls|gfx|d2d1|dwrite)\.(dll|exe)$'
# Faulting modules that point at the graphics stack (step 6).
$_gfxModule = '^(ig\w*|nv\w*|atidx\w*|amd\w*|d3d\w*|dxgi|oart\w*)\.dll$'

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
$_gfxKey  = if ($_hku) { "$_hku\Software\Microsoft\Office\$_officeVer\Common\Graphics" } else { $null }

$regPath = "HKLM:\Software\AirWatch\Extension\DEXRecords\${_regApp}Errors"

# -- Cross-step state (filled by step 2, read by 6) --
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

# -- Step Definitions --
$Steps = @(

    @{
        Name             = 'Crash and Hang History'
        Order            = 2
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            # Blame bookkeeping for later steps (the suite add-in script remediates both causes):
            # any entry under Office's Resiliency keys means Office already disabled something.
            if ($_hku) {
                $rk = "$_hku\Software\Microsoft\Office\$_officeVer\$_regApp\Resiliency"; $rn = 0
                foreach ($sub in 'DisabledItems', 'StartupItems') { if (Test-Path "$rk\$sub") { $rn += @((Get-Item "$rk\$sub").GetValueNames()).Count } }
                if ($rn -gt 0) { $script:_blame += 'disabled-items' }
            }
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
            }            if ($script:_crash.ThirdParty) { $script:_blame += 'add-in' }
            $detail = "$($crashes.Count) crash(es), $($hangs.Count) hang(s) in 7 days"
            if ($mod) { $detail += "; last faulting module $mod$(if ($modPath) { " ($modPath)" })$(if ($script:_crash.ThirdParty) { ' -- not an Office module, likely an add-in' } elseif ($mod -match $_gfxModule) { ' -- graphics stack' })" }
            if ($ev.Count -ge $CrashWarnCount7d) {
                return @{ Status = 'Failed'; Message = "$detail (threshold $CrashWarnCount7d). Step 6 uses this." }
            }
            return @{ Status = 'Warning'; Message = "$detail (threshold $CrashWarnCount7d)." }
        }
        ResolutionScript = $null
    },

    # Orders 3 (COM Add-in Conflict) and 4 (Office-Disabled Items) live in
    # ApplicationSpecific\Microsoft\Office\Invoke-AutoRemediateOfficeAddins.ps1.

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
        Name             = 'Graphics Acceleration Fault'
        Order            = 6
        Enabled          = $true
        ResolveOnWarning = $AllowDestructiveActions
        DetectionScript  = {
            if (-not $_hku) { return $_noUser }
            $cur = (Get-ItemProperty $_gfxKey -ErrorAction SilentlyContinue).DisableHardwareAcceleration
            $mod = $script:_crash.Module
            if (-not $mod -or $mod -notmatch $_gfxModule) {
                return @{ Status = 'Passed'; Message = "No graphics-stack crash in 7 days$(if ($cur -eq 1) { ' (hardware acceleration is already disabled for Office)' })." }
            }
            $script:_blame += 'graphics'
            if ($cur -eq 1) {
                return @{ Status = 'Warning'; Message = "Last crash faulted in $mod with Office hardware acceleration already disabled. Nothing further to set locally; this points at the display driver itself." }
            }
            return @{ Status = 'Warning'; Message = "Last crash faulted in $mod (graphics stack), $($script:_crash.Count) crash/hang event(s) in 7 days. Setting Common\Graphics\DisableHardwareAcceleration=1 -- this turns off GPU rendering for EVERY Office app for this user$(_Gate)." }
        }
        ResolutionScript = {
            if (-not (Test-Path $_gfxKey)) { New-Item -Path $_gfxKey -Force -ErrorAction Stop | Out-Null }
            Set-ItemProperty -Path $_gfxKey -Name 'DisableHardwareAcceleration' -Value 1 -Type DWord -ErrorAction Stop
            return @{ Remediated = $true; Message = "DisableHardwareAcceleration=1 set under Common\Graphics; takes effect at the next launch of each Office app. Revert by deleting the value once the display driver is updated." }
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
        Name             = 'Blank Template Health'
        Order            = 10
        Enabled          = $true
        ResolveOnWarning = $AllowDestructiveActions
        DetectionScript  = {
            if (-not $_userProfile) { return $_noUser }
            $tpl = Join-Path $_userProfile 'AppData\Roaming\Microsoft\Templates\Blank.potx'
            if (-not (Test-Path -LiteralPath $tpl)) {
                return @{ Status = 'Passed'; Message = "No user Blank.potx; $_app uses the built-in default theme." }
            }
            $f  = Get-Item -LiteralPath $tpl
            $mb = [math]::Round($f.Length / 1MB, 2)
            if ($mb -lt $TemplateWarnMB) {
                return @{ Status = 'Passed'; Message = "Blank.potx is ${mb}MB (threshold ${TemplateWarnMB}MB), modified $($f.LastWriteTime.ToString('yyyy-MM-dd'))." }
            }
            $script:_blame += 'template'
            $open = if (_AppOpen) { " $_app is open, so the rename waits for a run with $_app closed." } else { '' }
            return @{ Status = 'Warning'; Message = "Blank.potx is ${mb}MB (threshold ${TemplateWarnMB}MB); every new presentation starts from it. Rename to Blank_<stamp>.potx.bak so $_app falls back to the default theme; the user's theme stays in the backup$(_Gate).$open" }
        }
        ResolutionScript = {
            if (_AppOpen) { return @{ Remediated = $false; Status = 'Warning'; Message = "Blank.potx rename skipped: $_app is open. Re-run with $_app closed." } }
            $tpl = Join-Path $_userProfile 'AppData\Roaming\Microsoft\Templates\Blank.potx'
            $new = "Blank_$(Get-Date -Format 'yyyyMMdd-HHmmss').potx.bak"
            Rename-Item -LiteralPath $tpl -NewName $new -ErrorAction Stop
            return @{ Remediated = $true; Message = "Blank.potx renamed to $new; $_app uses the default theme until a new one is saved." }
        }
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
    Set-ItemProperty -Path $regPath -Name 'ScriptVersion'   -Value '1.0.3'       -Type String
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

Invoke-AutoRemediatePowerPoint
Exit 0
