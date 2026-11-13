<#
.SYNOPSIS
    Restart-CrashedServices -- finds Windows services that terminated unexpectedly and are
    still stopped, and starts them. Takes no input: the script identifies its own targets.

.DESCRIPTION
    The self-targeting counterpart to Restart-WinService.ps1 for use where no script
    variable can be passed. The target is derived from the root cause instead of named:

      1. Read Service Control Manager events from the System log for the last
         $LookbackHours: 7031 and 7034 ("terminated unexpectedly") and, with
         $IncludeStartFailures, the start failures 7000 (failed to start), 7001 (a
         dependency failed), 7009 (timed out connecting), 7022 (hung on starting),
         7023 and 7024 (terminated with an error). A service that never came up at
         boot is the same case as one that crashed: Automatic, stopped, with a
         failure on record. 7038 (logon failure) is left out; a start cannot fix it.
      2. Keep the services that are Stopped right now, are not Disabled, are Automatic
         (Manual too when $RestartManualServices), and are not on the deny list.
      3. Start them, most recent crash first, at most $MaxRestartsPerRun per run.

    A service that crashed and was brought back by its own SCM recovery action is Running
    and is reported only. A service this script has already started $MaxRestartsPerCooldown
    times within $CooldownHours is held: it keeps crashing, a restart is not the fix, and
    the run exits 1 so it is seen. Restart history is kept under
    HKLM:\Software\AirWatch\Extensions\ServiceRecovery\Crashed\<ServiceName>.

    Limit: Windows no longer logs service start/stop events (7036), so a service that
    crashed, recovered and was then stopped on purpose inside the lookback window looks
    the same as one that crashed and stayed down, and is started. Disabled is always
    respected; set a service Disabled to keep it off.

.NOTES
    Script Name  : Restart-CrashedServices.ps1
    Version      : 1.1.0
    Architecture : Any (x86/x64/ARM64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-12
    Timeout      : 60 seconds

    1.1.0: start-failure events (7000, 7001, 7009, 7022, 7023, 7024) count as well as
    crashes; an event is matched to its service by any of its parameters, since 7009
    carries the service name second.

    Inputs: none required. Settings are the constants in the SETTINGS block below.
      WhatIf   Optional environment variable; an explicit "true" reports without starting.

    Exit codes: 0 = nothing to do, or every selected service started;
                1 = a start failed, a service is held in cool-down, or not elevated.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

# ==============================================================================
# SETTINGS -- edit here; there are no script variables to pass.
# ==============================================================================
$MaxRestartsPerRun      = 2       # services started in one run; the rest are reported
$LookbackHours          = 24      # how far back a crash event counts
$IncludeStartFailures   = $true   # also act on services that failed to start (7000, 7001, 7009, 7022, 7023, 7024)
$CooldownHours          = 24      # window for the per-service restart history
$MaxRestartsPerCooldown = 2       # starts allowed per service inside that window
$RestartManualServices  = $false  # Manual services are demand-started by Windows; report only
$StartWaitSeconds       = 20      # how long a started service gets to reach Running

# Never touched. Wildcards allowed; matched against the service short name.
$DenyList = @(
    # Core OS: a crash here ends the session or the boot; never a restart candidate
    'RpcSs','RpcEptMapper','DcomLaunch','LSM','SamSs','BrokerInfrastructure','SystemEventsBroker',
    'Power','PlugPlay','CoreMessagingRegistrar','gpsvc','Schedule','ProfSvc','UserManager',
    'EventLog','EventSystem','Winmgmt','StateRepository','AppXSvc','ClipSVC','CryptSvc',
    # Self-managing: Windows starts and stops these itself
    'TrustedInstaller','msiserver','WaaSMedicSvc','sppsvc','UsoSvc','wuauserv','DoSvc','InstallService',
    'edgeupdate*','gupdate*','MicrosoftEdgeElevationService','GoogleChromeElevationService','MapsBroker','tiledatamodelsvc',
    # Network identity and session transport
    'Dhcp','Dnscache','NlaSvc','nsi','netprofm','LanmanWorkstation','Netlogon','BFE','mpssvc',
    'TermService','UmRdpService','SessionEnv',
    # Security products: tamper-protected, own their own recovery
    'WinDefend','WdNisSvc','Sense','MDCoreSvc','SecurityHealthService','wscsvc','WdFilter',
    'CSFalcon*','CSAgent','Sentinel*','McAfee*','mfe*','masvc','macmnsvc','Trellix*','ds_agent','Amsp',
    'ntrtscan','TMBMServer','TmCCSF','CbDefense*','CarbonBlack*','Cylance*','SepMasterService','SophosHealth','Sophos*',
    # Management agents, including the one running this script
    'AirWatch*','AWACMClient','Workspace ONE*','VMwareHub*','Omnissa*','WS1*','CcmExec','HealthService',
    'IntuneManagementExtension','dmwappushservice','DmEnrollmentSvc',
    # VDI and hypervisor agents: have their own remediation scripts
    'WSNM','vmware-view*','hzn*','VMBlast','vmlm_*','Ctx*','Citrix*','BrokerAgent','PorticaService',
    'RDAgent*','VMTools','VGAuthService','vm3dservice','vmic*'
)
# ==============================================================================

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
#endregion

function Get-ErrorText {
    # The service cmdlets put the useful cause in InnerException ("Cannot start service" is the wrapper).
    param($ErrorRecord)
    $text = $ErrorRecord.Exception.Message
    $inner = $ErrorRecord.Exception.InnerException
    while ($inner) { $text += " $($inner.Message)"; $inner = $inner.InnerException }
    return $text
}

function Test-Denied {
    param([string]$Name)
    foreach ($d in $DenyList) { if ($Name -like $d) { return $true } }
    return $false
}

# Restart history: one key per service, value History = ISO timestamps of this script's starts.
$HistoryRoot = 'HKLM:\Software\AirWatch\Extensions\ServiceRecovery\Crashed'

function Get-RestartHistory {
    # Timestamps inside the cool-down window, oldest first.
    param([string]$Name)
    $cutoff = (Get-Date).AddHours(-$CooldownHours)
    $raw = $null
    try { $raw = (Get-ItemProperty -Path "$HistoryRoot\$Name" -Name History -ErrorAction Stop).History } catch { }
    $kept = @()
    foreach ($s in @($raw)) {
        if ([string]::IsNullOrEmpty("$s")) { continue }
        try { $t = [datetime]::Parse("$s", $null, [System.Globalization.DateTimeStyles]::RoundtripKind) } catch { continue }
        if ($t -ge $cutoff) { $kept += $t }
    }
    return ,@($kept | Sort-Object)
}

function Add-RestartHistory {
    param([string]$Name)
    try {
        $prev = Get-RestartHistory -Name $Name
        $all = @($prev) + @(Get-Date)
        $key = "$HistoryRoot\$Name"
        if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
        New-ItemProperty -Path $key -Name History -PropertyType MultiString -Force `
            -Value ([string[]]@($all | ForEach-Object { $_.ToString('o') })) | Out-Null
    } catch {
        Write-Output "$HEAD Warning: could not record the restart of $Name for the cool-down: $($_.Exception.Message)"
    }
}

# -- entry point ---------------------------------------------------------------
$SCRIPT_VERSION = '1.1.0'
$RunEventId     = ([Random]::new()).Next(1000,9999)
$HEAD           = "[$RunEventId]"
$failures       = 0

Write-Output "$HEAD Executing Restart-CrashedServices, $SCRIPT_VERSION. Started @ '$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))'"

# Default to a LIVE run. Only an explicit, parseable "true" enables WhatIf.
$whatIf = $false
if ($env:WhatIf) { try { $whatIf = [System.Convert]::ToBoolean($env:WhatIf) } catch { $whatIf = $false } }

$principal = New-Object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $whatIf -and -not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Output "$HEAD Error: not elevated. Run as SYSTEM or an administrator."
    Exit 1
}

# -- 1. crash events -------------------------------------------------------------
$since    = (Get-Date).AddHours(-$LookbackHours)
$crashIds = 7031, 7034
$eventIds = if ($IncludeStartFailures) { $crashIds + 7000, 7001, 7009, 7022, 7023, 7024 } else { $crashIds }
$events   = @()
try {
    $events = @(Get-DexEvent -LogName 'System' -ProviderName 'Service Control Manager' -Id $eventIds -StartTime $since -ErrorStop)
} catch {
    Write-Output "$HEAD Error: could not read the System event log: $($_.Exception.Message)"
    Exit 1
}

if ($events.Count -eq 0) {
    Write-Output "$HEAD No service crash or start-failure events in the last $LookbackHours h. Nothing to do."
    Exit 0
}

# -- 2. map events to services ---------------------------------------------------
# Never enumerate with Get-Service: under PowerShell 7 it aborts on a protected service.
$services = @(Get-CimInstance -ClassName Win32_Service -ErrorAction SilentlyContinue)
$byName = @{}; $byDisplay = @{}
foreach ($s in $services) { $byName[$s.Name.ToLower()] = $s; $byDisplay["$($s.DisplayName)".ToLower()] = $s }

# The event's binary payload is the short name in UTF-16, which is locale-independent,
# so that is tried first. Otherwise the display name is one of the parameters: the
# first on most events, the second on 7009 (the first is the timeout), so each
# parameter is tried in order.
$crashes = @{}   # short name -> @{ Service; Latest; Crashed; StartFailed }
$unmatched = @{}
foreach ($ev in $events) {
    $svc = $null
    $props = @($ev.Properties)
    foreach ($p in $props) {
        if ($p.Value -is [byte[]]) {
            $short = [System.Text.Encoding]::Unicode.GetString($p.Value).Trim([char]0, ' ')
            if ($short -and $byName.ContainsKey($short.ToLower())) { $svc = $byName[$short.ToLower()] }
        }
    }
    $display = ''
    if (-not $svc) {
        foreach ($p in $props) {
            if ($p.Value -is [byte[]]) { continue }
            $v = "$($p.Value)".ToLower()
            if (-not $v) { continue }
            if ($byDisplay.ContainsKey($v)) { $svc = $byDisplay[$v]; break }
            if ($byName.ContainsKey($v))    { $svc = $byName[$v]; break }
        }
        if (-not $svc) {
            $i = if ($ev.Id -eq 7009 -and $props.Count -gt 1) { 1 } else { 0 }
            if ($props.Count -gt $i) { $display = "$($props[$i].Value)" }
        }
    }
    if (-not $svc) { if ($display) { $unmatched[$display] = $true }; continue }
    if (-not $crashes.ContainsKey($svc.Name)) {
        $crashes[$svc.Name] = @{ Service = $svc; Latest = $ev.TimeCreated; Crashed = 0; StartFailed = 0 }   # events arrive newest first
    }
    if ($crashIds -contains $ev.Id) { $crashes[$svc.Name].Crashed++ } else { $crashes[$svc.Name].StartFailed++ }
}

foreach ($u in $unmatched.Keys) {
    Write-Output "$HEAD Info: '$u' has a failure event but no longer exists as a service (removed, or a per-user service instance). Skipped."
}

# -- 3. classify -----------------------------------------------------------------
$candidates = @()
foreach ($c in ($crashes.Values | Sort-Object { $_.Latest } -Descending)) {
    $s     = $c.Service
    $label = "$($s.DisplayName) ($($s.Name))"
    $kinds = @()
    if ($c.Crashed -gt 0)     { $kinds += "crashed $($c.Crashed)x" }
    if ($c.StartFailed -gt 0) { $kinds += "failed to start $($c.StartFailed)x" }
    $what  = "$($kinds -join ' and '), last $($c.Latest.ToString('yyyy-MM-dd HH:mm:ss'))"

    if ($s.State -ne 'Stopped') {
        Write-Output "$HEAD OK: $label $what; now $($s.State) (recovered). No action."
        continue
    }
    if (Test-Denied -Name $s.Name) {
        Write-Output "$HEAD Skipped: $label $what and is stopped, but is on the deny list."
        continue
    }
    if ($s.StartMode -eq 'Disabled') {
        Write-Output "$HEAD Skipped: $label $what; startup type is Disabled, which this script does not override."
        continue
    }
    if ($s.StartMode -ne 'Auto' -and -not $RestartManualServices) {
        Write-Output "$HEAD Skipped: $label $what; startup type is $($s.StartMode), Windows starts it on demand."
        continue
    }
    $history = Get-RestartHistory -Name $s.Name
    if ($history.Count -ge $MaxRestartsPerCooldown) {
        $failures++
        Write-Output "$HEAD Held: $label $what and is stopped, but this script already started it $($history.Count)x in the last $CooldownHours h (last $($history[-1].ToString('yyyy-MM-dd HH:mm:ss'))). It keeps failing; a restart is not the fix. Not started."
        continue
    }
    $candidates += @{ Service = $s; Label = $label; What = $what }
}

if ($candidates.Count -eq 0) {
    Write-Output "$HEAD No crashed or failed service needs starting."
    if ($failures -gt 0) { Exit 1 }
    Exit 0
}

# -- 4. start, newest crash first, capped ------------------------------------------
$started = 0
foreach ($c in $candidates) {
    $name = $c.Service.Name
    if ($started -ge $MaxRestartsPerRun) {
        Write-Output "$HEAD Deferred: $($c.Label) $($c.What); the limit of $MaxRestartsPerRun starts per run is reached. The next run takes it."
        continue
    }
    $started++
    if ($whatIf) {
        Write-Output "$HEAD WhatIf: would start $($c.Label) ($($c.What))."
        continue
    }
    try {
        # ServiceController.Start returns once the SCM accepts the request; Start-Service
        # would block for the full service timeout on a service that hangs while starting.
        $sc = Get-Service -Name $name -ErrorAction Stop
        $sc.Start()
        try { $sc.WaitForStatus('Running', [TimeSpan]::FromSeconds($StartWaitSeconds)) } catch { }
        $sc.Refresh()
        Add-RestartHistory -Name $name
        if ($sc.Status -eq 'Running') {
            Write-Output "$HEAD $($c.Label) has been started ($($c.What))."
        } else {
            $failures++
            Write-Output "$HEAD Error, $($c.Label) was started but is $($sc.Status) after $StartWaitSeconds s ($($c.What))."
        }
    } catch {
        $failures++
        Add-RestartHistory -Name $name
        Write-Output "$HEAD Error, $($c.Label) could not be started: $(Get-ErrorText $_)"
    }
}

if ($failures -gt 0) { Exit 1 }
Exit 0
