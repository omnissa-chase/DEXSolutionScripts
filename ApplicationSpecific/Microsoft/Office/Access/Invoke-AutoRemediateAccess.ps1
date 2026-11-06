<#
.SYNOPSIS
    Invoke-AutoRemediateAccess -- Automated Microsoft Access diagnostic and remediation.

.DESCRIPTION
    Sequenced Access health checks with remediation where safe. Self-contained; built for
    Workspace ONE remediation or standalone use. Network, disk, memory and Windows
    Update belong to the generic scripts -- run those first.

    | Step | Name                         | Remediates On                       |
    |  2   | Crash and Hang History       | -- (report only; feeds 6)           |
    |  6   | Trusted Locations            | -- (report only)                    |
    |  7   | Database Size and Locks      | -- (report only)                    |
    |  8   | Office C2R Update Health     | DISABLED (Word owns it)             |

    Pre-flight: no MSACCESS.EXE under the Click-to-Run root = "not installed", exit 0.
    Steps 2 and 8 are the common Office steps (spec C2, C8); same engine as the Word
    script. Steps 3 (COM Add-in Conflict) and 4 (Office-Disabled Items) moved to
    ApplicationSpecific\Microsoft\Office\Invoke-AutoRemediateOfficeAddins.ps1, which
    covers all six Office applications in one run; their numbers stay as gaps so
    DEXRecords names hold. Step 8 is suite-wide and ships Enabled = $false here. Spec C5
    (AutoRecover) does not apply: Access has no AutoRecover. Spec C7 (Office Document
    Cache) is replaced by the product step 7. One script per product until UEM has
    dynamic variables.

    Steps 6 and 7 work from the user's File MRU (the databases actually opened). Step 6
    fires only after a crash in step 2 and names databases outside every trusted
    location (user hive and policy). Step 7 is the spec's compact-on-close step: it
    reports databases near the 2 GB engine limit and stale .laccdb/.ldb lock files
    left beside a database while no MSACCESS.EXE runs (the "file already in use"
    ticket). Both report only: trust and database maintenance belong to the owner.

    SYSTEM context: profile and hive come from Win32_ComputerSystem.UserName and
    HKU\<SID>, never $env:APPDATA. No interactive user: per-user steps Warn "skipped".

.PARAMETER CacheSizeWarningMB
    Database size that turns step 7 Warning. Default 1536 (engine limit is 2048).
.PARAMETER AllowDestructiveActions
    No gated step remains here (step 3 moved to the suite add-in script); kept for
    family parity. Default $false.
.PARAMETER CrashWarnCount7d
    Crash plus hang count in 7 days that turns step 2 Failed. Default 3.
.PARAMETER TemplateWarnMB
    Unused here; kept for family parity. Default 8. Every input also reads $env:<name>.

.NOTES
    Script Name  : Invoke-AutoRemediateAccess.ps1
    Version      : 1.0.3
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-05 (1.0.3: the COM Add-in Conflict and Office-Disabled Items steps moved to
                   ApplicationSpecific\Microsoft\Office\Invoke-AutoRemediateOfficeAddins.ps1, which covers
                   all six Office applications in one run; step numbering kept (3 and 4 are now gaps); the
                   ReenableDisabledItems input moved with them. 1.0.2: step 3 returns Warning, not Failed, when a crash names
                   an add-in while AllowDestructiveActions is off, so the gate its message
                   promises holds; the engine remediates every Failed. 1.0.1: crash and hang events read through the .NET EventLogReader; Get-WinEvent fails in every form under Hub's ARM64 PowerShell 7.2 engine; 1.0.0: first build from App_Remediation_Specs.md section 12)
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

function Invoke-AutoRemediateAccess {
param(
    [int] $CacheSizeWarningMB      = $(if ($env:CacheSizeWarningMB) { [int]$env:CacheSizeWarningMB } else { 1536 }),
    [bool]$AllowDestructiveActions = $(if ($env:AllowDestructiveActions) { [System.Convert]::ToBoolean($env:AllowDestructiveActions) } else { $false }),
    [int] $CrashWarnCount7d        = $(if ($env:CrashWarnCount7d) { [int]$env:CrashWarnCount7d } else { 3 }),
    [int] $TemplateWarnMB          = $(if ($env:TemplateWarnMB) { [int]$env:TemplateWarnMB } else { 8 })
)

# -- Product identity (the only product-specific constants) --
$_app      = 'Access'
$_exe      = 'MSACCESS.EXE'
$_proc     = 'MSACCESS'
$_regApp   = 'Access'
# Office's own modules; a fault in one of these is not an add-in's fault.
$_msModule = '^(msaccess|ace\w*|msjet\w*|wwlib|mso\w*|oart\w*|office|msvc\w*|vcruntime\w*|ucrtbase|ntdll|kernel\w*|user32|gdi32|combase|ole\w*|rpcrt4|clr|coreclr|riched20|msptls|gfx|d2d1|dwrite)\.(dll|exe)$'

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
$_appKey = if ($_hku) { "$_hku\Software\Microsoft\Office\$_officeVer\$_regApp" } else { $null }

$regPath = "HKLM:\Software\AirWatch\Extension\DEXRecords\${_regApp}Errors"

# -- Cross-step state (filled by step 2, read by 6) --
$script:_crash = @{ Count = 0; Hangs = 0; Module = ''; ModulePath = ''; ThirdParty = $false }
$script:_blame = @()   # step names that found something to blame

function _Expand([string]$s) { if ($s) { [Environment]::ExpandEnvironmentVariables($s) } else { $s } }
function _AppOpen { [bool](Get-Process -Name $_proc -ErrorAction SilentlyContinue) }
function _Gate { if ($AllowDestructiveActions) { '' } else { ' -- set $AllowDestructiveActions=$true to apply' } }
function _MruDatabases {
    # File MRU items look like [F00000000][T01DA...][O00000000]*C:\path\db.accdb
    $list = @()
    $mru = Get-ItemProperty "$_appKey\File MRU" -ErrorAction SilentlyContinue
    if (-not $mru) { return $list }
    $mru.PSObject.Properties | Where-Object { $_.Name -match '^Item \d+$' } | ForEach-Object {
        $p = _Expand (("$($_.Value)" -replace '^(\[[^\]]*\])*\*', '').Trim())
        if ($p -match '\.(accd[a-z]|md[a-z])$' -and $p -notmatch '^(https?://|\\\\)') { $list += $p }
    }
    return $list | Select-Object -Unique
}
function _TrustedLocations {
    $list = @()
    foreach ($root in @("$_appKey\Security\Trusted Locations", "$_hku\Software\Policies\Microsoft\Office\$_officeVer\$_regApp\Security\Trusted Locations")) {
        Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
            $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if ($p.Path) { $list += [PSCustomObject]@{ Path = (_Expand "$($p.Path)").TrimEnd('\') + '\'; Sub = ([int]$p.AllowSubfolders -eq 1) } }
        }
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
            # Blame bookkeeping for later steps (the suite add-in script remediates both causes):
            # any entry under Office's Resiliency keys means Office already disabled something.
            if ($_appKey) {
                $rk = "$_appKey\Resiliency"; $rn = 0
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
            if ($mod) { $detail += "; last faulting module $mod$(if ($modPath) { " ($modPath)" })$(if ($script:_crash.ThirdParty) { ' -- not an Office module, likely an add-in' })" }
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
        Name             = 'Trusted Locations'
        Order            = 6
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            if (-not $_hku) { return $_noUser }
            if ($script:_crash.Count -eq 0) {
                return @{ Status = 'Passed'; Message = 'Not indicated: no crash or hang in 7 days.' }
            }
            $dbs = @(_MruDatabases)
            if ($dbs.Count -eq 0) {
                return @{ Status = 'Passed'; Message = 'No local databases in the recent-file list to check.' }
            }
            $trusted = @(_TrustedLocations)
            $untrusted = @($dbs | Where-Object {
                $db = $_; $dir = (Split-Path $db -Parent).TrimEnd('\') + '\'
                -not ($trusted | Where-Object { ($_.Sub -and $db.StartsWith($_.Path, 'OrdinalIgnoreCase')) -or ($dir -ieq $_.Path) })
            })
            if ($untrusted.Count -eq 0) {
                return @{ Status = 'Passed'; Message = "All $($dbs.Count) recent database(s) sit under a trusted location ($($trusted.Count) defined)." }
            }
            return @{ Status = 'Warning'; Message = "$($untrusted.Count) of $($dbs.Count) recent database(s) open from outside the $($trusted.Count) trusted location(s): $(($untrusted | Select-Object -First 3) -join ', '). Macros and VBA run disabled there and some solutions fail or crash as a result. Report only: trust decisions are policy." }
        }
        ResolutionScript = $null
    },

    @{
        Name             = 'Database Size and Locks'
        Order            = 7
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            if (-not $_hku) { return $_noUser }
            $dbs = @(_MruDatabases | Where-Object { Test-Path -LiteralPath $_ })
            if ($dbs.Count -eq 0) {
                return @{ Status = 'Passed'; Message = 'No reachable local databases in the recent-file list.' }
            }
            $big = @(); $locks = @()
            $running = _AppOpen
            foreach ($db in $dbs) {
                $f  = Get-Item -LiteralPath $db -ErrorAction SilentlyContinue
                if (-not $f) { continue }
                $mb = [math]::Round($f.Length / 1MB)
                if ($mb -ge $CacheSizeWarningMB) { $big += "$($f.Name) (${mb}MB)" }
                $lock = Join-Path $f.DirectoryName ([IO.Path]::GetFileNameWithoutExtension($f.Name) + $(if ($f.Extension -like '.accd*') { '.laccdb' } else { '.ldb' }))
                if ((Test-Path -LiteralPath $lock) -and -not $running) { $locks += $lock }
            }
            if ($big.Count -eq 0 -and $locks.Count -eq 0) {
                return @{ Status = 'Passed'; Message = "$($dbs.Count) recent database(s) under ${CacheSizeWarningMB}MB with no stale lock files." }
            }
            $msg = @()
            if ($big.Count -gt 0)   { $msg += "near the 2GB engine limit: $($big -join ', ') -- the owner should compact and repair" }
            if ($locks.Count -gt 0) { $msg += "stale lock file(s) with no $_app running: $(($locks | Select-Object -First 3) -join ', ') -- another user or a crashed session holds them; expect 'file already in use'" }
            return @{ Status = 'Warning'; Message = "$($msg -join '; '). Report only; the database owner acts on this." }
        }
        ResolutionScript = $null
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

Invoke-AutoRemediateAccess
Exit 0
