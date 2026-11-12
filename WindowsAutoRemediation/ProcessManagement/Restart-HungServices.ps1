<#
.SYNOPSIS
    Restart-HungServices -- finds Windows services stuck in a Starting or Stopping state,
    ends the stuck service process, and brings the service back. Takes no input: the
    script identifies its own targets.

.DESCRIPTION
    The self-targeting counterpart to Restart-WinService.ps1 for use where no script
    variable can be passed. The target is derived from the root cause instead of named:

      1. Find services in a pending state (Start Pending, Stop Pending, Continue Pending,
         Pause Pending).
      2. Watch them, polling every $PollSeconds, until each one either leaves the pending
         state by itself (not hung: no action) or has been stuck for $HungAfterSeconds.
         A service that is merely slow is never touched.
      3. For a stuck service: end its process, wait for the SCM to mark it Stopped, then
           stuck starting            -> start it again
           stuck stopping, Automatic -> start it again (a restart that hung half way)
           stuck stopping, Manual    -> leave it stopped (the stop was the intent)
         At most $MaxRestartsPerRun services per run.

    Never ended: a process that hosts any other service (a shared svchost; ending it
    would take healthy services down), a Windows-critical process, and anything on the
    deny list. Those are reported and the run exits 1, because the hang is still there
    and usually needs a reboot.

    A service this script has already recovered $MaxRestartsPerCooldown times within
    $CooldownHours is held: it keeps hanging, a restart is not the fix, and the run exits
    1 so it is seen. History is kept under
    HKLM:\Software\AirWatch\Extensions\ServiceRecovery\Hung\<ServiceName>.

    Not covered: a service that reports Running but no longer answers. Nothing generic
    identifies that state.

.NOTES
    Script Name  : Restart-HungServices.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64/ARM64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-12
    Timeout      : 180 seconds (the watch alone can take $HungAfterSeconds)

    Inputs: none required. Settings are the constants in the SETTINGS block below.
      WhatIf   Optional environment variable; an explicit "true" reports without acting.

    Exit codes: 0 = nothing hung, or every hung service recovered;
                1 = a recovery failed, a hung service could not be touched (shared host,
                    deny list, cool-down), or not elevated.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

# ==============================================================================
# SETTINGS -- edit here; there are no script variables to pass.
# ==============================================================================
$MaxRestartsPerRun      = 2     # services recovered in one run; the rest are reported
$HungAfterSeconds       = 60    # stuck in one pending state this long = hung
$PollSeconds            = 5     # how often the watch re-reads the state
$CooldownHours          = 24    # window for the per-service recovery history
$MaxRestartsPerCooldown = 2     # recoveries allowed per service inside that window
$StopWaitSeconds        = 15    # how long the SCM gets to mark the service Stopped after its process ends
$StartWaitSeconds       = 20    # how long a started service gets to reach Running

# Never touched. Wildcards allowed; matched against the service short name.
$DenyList = @(
    # Core OS: ending these ends the session or the machine
    'RpcSs','RpcEptMapper','DcomLaunch','LSM','SamSs','BrokerInfrastructure','SystemEventsBroker',
    'Power','PlugPlay','CoreMessagingRegistrar','gpsvc','Schedule','ProfSvc','UserManager',
    'EventLog','EventSystem','Winmgmt','StateRepository','AppXSvc','ClipSVC','CryptSvc',
    # Self-managing: Windows starts and stops these itself, and an install may be mid-flight
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

# Processes never ended, whatever service they host.
$CriticalProcesses = @('System','Idle','smss','csrss','wininit','winlogon','services','lsass','lsaiso','MsMpEng','Registry','Memory Compression')
# ==============================================================================

function Get-ErrorText {
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

function Get-ServiceCim {
    param([string]$Name)
    $n = $Name -replace "'", "''"
    Get-CimInstance -ClassName Win32_Service -Filter "Name='$n'" -ErrorAction SilentlyContinue
}

# Recovery history: one key per service, value History = ISO timestamps of this script's recoveries.
$HistoryRoot = 'HKLM:\Software\AirWatch\Extensions\ServiceRecovery\Hung'

function Get-RestartHistory {
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
        Write-Output "$HEAD Warning: could not record the recovery of $Name for the cool-down: $($_.Exception.Message)"
    }
}

# -- entry point ---------------------------------------------------------------
$SCRIPT_VERSION = '1.0.0'
$RunEventId     = ([Random]::new()).Next(1000,9999)
$HEAD           = "[$RunEventId]"
$failures       = 0

Write-Output "$HEAD Executing Restart-HungServices, $SCRIPT_VERSION. Started @ '$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))'"

# Default to a LIVE run. Only an explicit, parseable "true" enables WhatIf.
$whatIf = $false
if ($env:WhatIf) { try { $whatIf = [System.Convert]::ToBoolean($env:WhatIf) } catch { $whatIf = $false } }

$principal = New-Object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $whatIf -and -not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Output "$HEAD Error: not elevated. Run as SYSTEM or an administrator."
    Exit 1
}

# -- 1. services in a pending state ------------------------------------------------
# CIM, never Get-Service: under PowerShell 7 Get-Service aborts on a protected service.
$pending = @(Get-CimInstance -ClassName Win32_Service -Filter "State LIKE '%Pending'" -ErrorAction SilentlyContinue)
if ($pending.Count -eq 0) {
    Write-Output "$HEAD No service is in a pending state. Nothing to do."
    Exit 0
}

# -- 2. watch: slow is not hung ----------------------------------------------------
# A service is hung only if it holds the same pending state in the same process for the
# whole watch. Anything that moves on, or whose process changes, is dropped.
$watch = @{}
foreach ($s in $pending) { $watch[$s.Name] = @{ State = $s.State; ProcessId = [int]$s.ProcessId; DisplayName = $s.DisplayName; StartMode = $s.StartMode } }
Write-Output "$HEAD Pending: $(@($pending | ForEach-Object { "$($_.Name) [$($_.State)]" }) -join ', '). Watching for up to $HungAfterSeconds s."

$sw = [System.Diagnostics.Stopwatch]::StartNew()
while ($watch.Count -gt 0 -and $sw.Elapsed.TotalSeconds -lt $HungAfterSeconds) {
    Start-Sleep -Seconds $PollSeconds
    foreach ($name in @($watch.Keys)) {
        $now = Get-ServiceCim -Name $name
        if (-not $now -or $now.State -ne $watch[$name].State -or [int]$now.ProcessId -ne $watch[$name].ProcessId) {
            $nowState = if ($now) { $now.State } else { 'gone' }
            Write-Output "$HEAD OK: $($watch[$name].DisplayName) ($name) left '$($watch[$name].State)' after $([int]$sw.Elapsed.TotalSeconds) s (now $nowState). Slow, not hung. No action."
            $watch.Remove($name)
        }
    }
}

if ($watch.Count -eq 0) {
    Write-Output "$HEAD No service is hung."
    Exit 0
}

# -- 3. recover --------------------------------------------------------------------
$recovered = 0
foreach ($name in @($watch.Keys | Sort-Object)) {
    $w     = $watch[$name]
    $label = "$($w.DisplayName) ($name)"
    $what  = "stuck in '$($w.State)' for $HungAfterSeconds s"
    $procId = $w.ProcessId

    if (Test-Denied -Name $name) {
        $failures++
        Write-Output "$HEAD Not touched: $label is $what, but is on the deny list. Needs a reboot or its own tooling."
        continue
    }
    if ($procId -le 4) {
        $failures++
        Write-Output "$HEAD Not touched: $label is $what with no service process to end (PID $procId). Needs a reboot."
        continue
    }
    $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
    $procName = if ($proc) { $proc.ProcessName } else { '' }
    if ($CriticalProcesses -contains $procName) {
        $failures++
        Write-Output "$HEAD Not touched: $label is $what inside the critical process $procName (PID $procId). Needs a reboot."
        continue
    }
    $others = @(Get-CimInstance -ClassName Win32_Service -Filter "ProcessId=$procId" -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -ne $name } | ForEach-Object { $_.Name })
    if ($others.Count -gt 0) {
        $failures++
        Write-Output "$HEAD Not touched: $label is $what, but its process $procName (PID $procId) also hosts $($others -join ', '). Ending it would take those down. Needs a reboot."
        continue
    }
    $history = Get-RestartHistory -Name $name
    if ($history.Count -ge $MaxRestartsPerCooldown) {
        $failures++
        Write-Output "$HEAD Held: $label is $what, but this script already recovered it $($history.Count)x in the last $CooldownHours h (last $($history[-1].ToString('yyyy-MM-dd HH:mm:ss'))). It keeps hanging; a restart is not the fix. Not touched."
        continue
    }
    if ($recovered -ge $MaxRestartsPerRun) {
        $failures++
        Write-Output "$HEAD Deferred: $label is $what; the limit of $MaxRestartsPerRun recoveries per run is reached. The next run takes it."
        continue
    }
    $recovered++

    $startAfter = ($w.State -ne 'Stop Pending') -or ($w.StartMode -eq 'Auto')
    $plan = if ($startAfter) { 'end the process and start the service' } else { 'end the process and leave the service stopped (Manual; the stop was the intent)' }
    if ($whatIf) {
        Write-Output "$HEAD WhatIf: $label is $what in $procName (PID $procId); would $plan."
        continue
    }

    try {
        Stop-Process -Id $procId -Force -ErrorAction Stop
    } catch {
        $failures++
        Write-Output "$HEAD Error, $label is $what and its process $procName (PID $procId) could not be ended: $(Get-ErrorText $_)"
        continue
    }
    Add-RestartHistory -Name $name

    # The SCM notices the dead process and marks the service Stopped; a recovery action
    # configured on the service may start it again by itself.
    $deadline = (Get-Date).AddSeconds($StopWaitSeconds)
    do {
        Start-Sleep -Milliseconds 500
        $now = Get-ServiceCim -Name $name
    } while ($now -and $now.State -like '*Pending' -and [int]$now.ProcessId -eq $procId -and (Get-Date) -lt $deadline)

    if ($now -and $now.State -like '*Pending' -and [int]$now.ProcessId -eq $procId) {
        $failures++
        Write-Output "$HEAD Error, $label process $procName (PID $procId) was ended but the service is still '$($now.State)' after $StopWaitSeconds s."
        continue
    }

    if (-not $startAfter) {
        Write-Output "$HEAD $label was $what; process $procName (PID $procId) ended, service is now $($now.State). Left stopped (Manual)."
        continue
    }

    try {
        $sc = Get-Service -Name $name -ErrorAction Stop
        # Non-blocking start: Start-Service would sit out the full service timeout if it hangs again.
        if ($sc.Status -eq 'Stopped') { $sc.Start() }
        try { $sc.WaitForStatus('Running', [TimeSpan]::FromSeconds($StartWaitSeconds)) } catch { }
        $sc.Refresh()
        if ($sc.Status -eq 'Running') {
            Write-Output "$HEAD $label was $what; process $procName (PID $procId) ended and the service has been started."
        } else {
            $failures++
            Write-Output "$HEAD Error, $label was $what; process $procName (PID $procId) ended, but after a new start the service is $($sc.Status) after $StartWaitSeconds s. It hangs again."
        }
    } catch {
        $failures++
        Write-Output "$HEAD Error, $label was $what; process $procName (PID $procId) ended, but the service could not be started: $(Get-ErrorText $_)"
    }
}

if ($failures -gt 0) { Exit 1 }
Exit 0
