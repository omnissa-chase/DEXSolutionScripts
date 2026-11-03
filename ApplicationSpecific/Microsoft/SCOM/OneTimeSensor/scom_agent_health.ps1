#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : scom_agent_health
    Data Type    : String (JSON)
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-21
    Timeout      : One-time / run-once only. Self-enforced 25 s budget, 30 s UEM hard
                   ceiling. MUST NOT be scheduled as a recurring sensor. See
                   GENERAL-SCRIPTS-SENSORS_RUNBOOK.md section 10.

    A complete Operations Manager agent picture in one on-demand pull -- every metric
    the Sensors/ folder exposes plus several it cannot, as one compact JSON object.
    Reads no cache and writes nothing: it does its own detection, so it works on a
    device where the sweep has never run.

    WHY THIS IS SEPARATE FROM Sensors/
    Recurring sensors are dumb cache readers: under 2 s, no network. This one mines the
    event log and makes a real TCP probe -- only defensible for a genuine one-time run,
    since scheduled recurring it would block the fleet's serialized sensor queue for up
    to 25 s every interval. Hence its own folder.

    RELATIONSHIP TO THE SWEEP
    Use this for a single on-demand pull. Use Invoke-AutoRemediateSCOMAgentPart*.ps1
    plus Sensors/ for continuous fleet reporting. Covers all 14 sweep steps in one pass,
    no cache required.

    HealthScore/HealthReason mirror the sweep's deduction table condition for condition
    so the two agree. That duplication is intentional (this file must stay
    self-contained) but the table lives in two places: change Part 3's deductions and
    change these in the same edit. One deliberate divergence -- the sweep's TimeSkew is
    driven by measured clock skew, this one by time-sync age (see NOT COLLECTED), so the
    two can differ by those 15 points. Nothing else differs.

    SCOPE -- AGENT SIDE ONLY
    Where the finding is server-side (agent not approved, no parent management server,
    certificate expired, management server unreachable) the JSON says so and offers no
    remediation -- a device-side sensor cannot fix a management server.

    SELF-ENFORCED DEADLINE
    A Stopwatch is checked before each remaining phase; once the budget is spent,
    unattempted phases report -4 and TimedOut is set true. The UEM ceiling is a
    backstop, never the mechanism. When TimedOut is true HealthScore is a floor, not a
    verdict -- what the skipped phases would have deducted is missing. Filter on it
    before trending, as you would on -1.

    Sentinels for every numeric key:
      -1  Unknown        -- could not be measured
      -2  Not applicable -- feature or agent not present on this device
      -4  Timed out      -- self-enforced deadline reached before this phase ran

    HealthScore is the exception: -1 for "no agent installed", matching the sweep and
    Sensors/scom_agent_health_score.ps1 so the sources can be unioned. Read
    HealthReason alongside it.

    NOT COLLECTED, AND WHY
    Clock skew against a domain controller: measuring it means launching w32tm.exe, and
    a sensor must not launch external processes. TimeSyncAgeHours is a registry read of
    the last successful sync instead -- a proxy, not the same fact. Part 3 step 13
    measures real skew; so does GenericTroubleshooting/TimeSyncHealth.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

# -- Tunables --
# 25 s leaves a 5 s margin under the 30 s UEM one-time ceiling for JSON
# serialization and process teardown.
$script:TimeoutSeconds   = 25
$script:NetTimeoutMs     = 3000    # management server TCP probe
$script:EventLookbackHrs = 24
$script:MaxEventsScanned = 2000

# Thresholds, identical to Invoke-AutoRemediateSCOMAgent.ps1. Kept in sync by hand;
# see "RELATIONSHIP TO THE SWEEP" above.
$script:ConfigStaleHours          = 24
$script:StateFolderWarnMB         = 1536
$script:StoreDbWarnMB             = 768
$script:RuntimeMemoryWarnMB       = 400
$script:RuntimeCpuWarnPercent     = 15
$script:ConnectFailureWarnCount   = 5
$script:UnloadedWorkflowWarnCount = 3
$script:CertExpiryWarnDays        = 30
$script:SyncStaleHours            = 48
$script:StartupDelayWarnSeconds   = 300

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

$UNKNOWN  = -1
$NOTAPPL  = -2
$TIMEDOUT = -4

# Pre-seeded to sentinels so a phase that throws or never runs still emits a
# type-valid key -- a missing key breaks downstream parsing rather than degrading it.
$r = [ordered]@{
    SchemaVersion          = 1
    CollectedAt            = (Get-Date -Format 's')
    TimedOut               = $false
    DurationMs             = $UNKNOWN

    AgentInstalled         = $false
    AgentVersion           = ''
    InstallDirectory       = ''

    ServicePresent         = $false
    ServiceStatus          = ''
    ServiceStartMode       = ''
    ServiceUptimeHours     = $UNKNOWN
    ServiceStartDelaySecs  = $UNKNOWN

    ManagementGroups       = @()
    ManagementGroupCount   = $UNKNOWN
    ManagementServer       = ''
    ManagementServerPort   = $UNKNOWN
    FailoverServerCount    = $UNKNOWN
    MsReachable            = $false
    MsProbeMs              = $UNKNOWN
    MsProbeResult          = ''

    ConfigAgeHours         = $UNKNOWN
    StateFolderMB          = $UNKNOWN
    StoreDbMB              = $UNKNOWN

    RuntimeMemoryMB        = $UNKNOWN
    RuntimeCpuPercent      = $UNKNOWN
    MonitoringHostCount    = $UNKNOWN

    OpsLogAvailable        = $false
    ConnectFailures24h     = $UNKNOWN
    AuthFailures24h        = $UNKNOWN
    NotRegistered24h       = $UNKNOWN
    UnloadedWorkflows24h   = $UNKNOWN
    ScriptFailures24h      = $UNKNOWN
    StoreDbErrors24h       = $UNKNOWN

    CertExpiryDays         = $NOTAPPL
    CertProblem            = $false

    TimeSyncAgeHours       = $UNKNOWN

    AdtAgentPresent        = $false
    ApmPresent             = $false

    HealthScore            = $UNKNOWN
    HealthReason           = 'Unknown'
    Findings               = @()
}

$sw = [System.Diagnostics.Stopwatch]::StartNew()

function Test-Budget {
    # $true while there is still time to attempt another phase.
    if ($sw.Elapsed.TotalSeconds -lt $script:TimeoutSeconds) { return $true }
    $r.TimedOut = $true
    return $false
}

function Write-Result {
    $sw.Stop()
    $r.DurationMs = [int]$sw.Elapsed.TotalMilliseconds
    try   { Write-Output (ConvertTo-Json -InputObject $r -Depth 4 -Compress) }
    catch { Write-Output '{"SchemaVersion":1,"HealthReason":"SerializationFailed"}' }
}

try {
    # -- Phase 1: agent discovery ---------------------------------------------
    $agentRoot = $null
    foreach ($candidate in @(
        'HKLM:\SOFTWARE\Microsoft\Microsoft Operations Manager\3.0',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Microsoft Operations Manager\3.0')) {
        if (Test-Path $candidate) { $agentRoot = $candidate; break }
    }

    $healthSvc = Get-Service -Name 'HealthService' -ErrorAction SilentlyContinue

    if (-not $agentRoot -and -not $healthSvc) {
        # Not a fault. This device was never in scope, and saying so in one place
        # keeps it out of every fleet average downstream.
        #
        # HealthScore is -1 here, not -2, even though every other key on this path is
        # -2. That is deliberate: -1 is what the sweep writes and what
        # Sensors/scom_agent_health_score.ps1 returns for "no agent installed", and a
        # score reported two different ways for one condition would break any report
        # that unions the two sources. HealthReason removes the ambiguity.
        $r.HealthScore  = $UNKNOWN
        $r.HealthReason = 'NoAgentInstalled'
        foreach ($k in @('ManagementGroupCount','ManagementServerPort','FailoverServerCount',
                         'MsProbeMs','ConfigAgeHours','StateFolderMB','StoreDbMB',
                         'RuntimeMemoryMB','RuntimeCpuPercent','MonitoringHostCount',
                         'ConnectFailures24h','AuthFailures24h','NotRegistered24h',
                         'UnloadedWorkflows24h','ScriptFailures24h','StoreDbErrors24h',
                         'ServiceUptimeHours','ServiceStartDelaySecs','TimeSyncAgeHours')) {
            $r[$k] = $NOTAPPL
        }
        $r.MsProbeResult = 'NoAgentInstalled'
        Write-Result
        return
    }

    $r.AgentInstalled = $true
    $installDir = ''

    if ($agentRoot) {
        $setup = Get-ItemProperty -Path (Join-Path $agentRoot 'Setup') -ErrorAction SilentlyContinue
        if ($setup) {
            if ($setup.InstallDirectory) { $installDir = [string]$setup.InstallDirectory }
            # Some builds expose ProductVersion rather than CurrentVersion.
            if     ($setup.CurrentVersion) { $r.AgentVersion = [string]$setup.CurrentVersion }
            elseif ($setup.ProductVersion) { $r.AgentVersion = [string]$setup.ProductVersion }
        }
    }

    $r.InstallDirectory = $installDir

    if (-not $r.AgentVersion -and $installDir) {
        $exe = Join-Path $installDir 'HealthService.exe'
        if (Test-Path -LiteralPath $exe) {
            $r.AgentVersion = [string](Get-Item -LiteralPath $exe -ErrorAction SilentlyContinue).VersionInfo.FileVersion
        }
    }

    $stateDir  = if ($installDir) { Join-Path $installDir 'Health Service State' } else { '' }
    $storeDb   = if ($stateDir)   { Join-Path $stateDir 'Health Service Store\HealthServiceStore.edb' } else { '' }
    $configDir = if ($stateDir)   { Join-Path $stateDir 'Connector Configuration Cache' } else { '' }

    # -- Phase 2: service state ------------------------------------------------
    if ($healthSvc) {
        $r.ServicePresent = $true
        $r.ServiceStatus  = [string]$healthSvc.Status

        $cim = Get-CimInstance -ClassName Win32_Service -Filter "Name='HealthService'" -ErrorAction SilentlyContinue
        if ($cim) {
            $r.ServiceStartMode = [string]$cim.StartMode
            if ($cim.ProcessId -gt 0) {
                $p = Get-Process -Id $cim.ProcessId -ErrorAction SilentlyContinue
                if ($p -and $p.StartTime) {
                    $r.ServiceUptimeHours = [int][math]::Round(((Get-Date) - $p.StartTime).TotalHours, 0)

                    # Sweep step 2. Same heuristic: process start against last boot, from
                    # data already in hand -- no event log query, no added runtime. A
                    # negative delta means the agent was restarted after boot, so the
                    # boot-time question does not apply.
                    $boot = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue).LastBootUpTime
                    if ($boot) {
                        $d = [int][math]::Round(($p.StartTime - $boot).TotalSeconds, 0)
                        $r.ServiceStartDelaySecs = if ($d -lt 0) { $NOTAPPL } else { $d }
                        if ($d -gt $script:StartupDelayWarnSeconds) {
                            $r.Findings += "HealthService started ${d}s after boot (threshold $($script:StartupDelayWarnSeconds)s) -- check the WMI/RPC dependency chain; on VDI this is usually storage contention at boot storm"
                        }
                    }
                }
            }
        }
    }
    else {
        # Registry present, service absent: a partial install or a partial removal.
        $r.ServiceStatus      = 'NotInstalled'
        $r.ServiceStartMode   = 'NotInstalled'
        $r.ServiceUptimeHours    = $NOTAPPL
        $r.ServiceStartDelaySecs = $NOTAPPL
        $r.Findings += 'HealthService not installed but agent registry keys exist -- partial install or partial removal'
    }

    # -- Phase 3: management group registration --------------------------------
    $parents = @()
    if ($agentRoot) {
        $mgRoot = Join-Path $agentRoot 'Agent Management Groups'
        if (Test-Path $mgRoot) {
            $groups = @(Get-ChildItem -Path $mgRoot -ErrorAction SilentlyContinue)
            $r.ManagementGroupCount = $groups.Count
            $r.ManagementGroups     = @($groups | ForEach-Object { [string]$_.PSChildName })

            foreach ($g in $groups) {
                $phs = Get-ChildItem -Path (Join-Path $g.PSPath 'Parent Health Services') -ErrorAction SilentlyContinue
                foreach ($ph in $phs) {
                    $props = Get-ItemProperty -Path $ph.PSPath -ErrorAction SilentlyContinue
                    if ($props -and $props.NetworkName) {
                        $parents += [PSCustomObject]@{
                            Network = [string]$props.NetworkName
                            Port    = if ($props.Port) { [int]$props.Port } else { 5723 }
                        }
                    }
                }
            }
        }
        else {
            $r.ManagementGroupCount = 0
        }
    }
    else {
        $r.ManagementGroupCount = $UNKNOWN
    }

    if ($parents.Count -gt 0) {
        # First parent is the primary; the remainder are failover.
        $r.ManagementServer     = $parents[0].Network
        $r.ManagementServerPort = $parents[0].Port
        $r.FailoverServerCount  = $parents.Count - 1
    }
    else {
        $r.ManagementServerPort = $NOTAPPL
        $r.FailoverServerCount  = $NOTAPPL
        if ($r.ManagementGroupCount -eq 0) {
            $r.Findings += 'No management group configured -- the agent has never been assigned'
        }
        elseif ($r.ManagementGroupCount -gt 0) {
            $r.Findings += 'Management group configured but no parent management server assigned -- the agent was never approved server-side, or its assignment was removed'
        }
    }

    if ($r.ManagementGroupCount -gt 1) {
        $r.Findings += "Agent is multi-homed to $($r.ManagementGroupCount) management groups -- every workflow set runs once per group"
    }

    # -- Phase 4: management server TCP probe ----------------------------------
    # The one network call in this file, and the reason it must stay a one-time
    # sensor. One attempt, hard-bounded, never retried.
    if (-not $r.ManagementServer) {
        $r.MsProbeMs     = $NOTAPPL
        $r.MsProbeResult = 'NoManagementServerConfigured'
    }
    elseif (Test-Budget) {
        $client = $null
        try {
            $probeSw = [System.Diagnostics.Stopwatch]::StartNew()
            $client  = New-Object System.Net.Sockets.TcpClient
            $async   = $client.BeginConnect($r.ManagementServer, $r.ManagementServerPort, $null, $null)

            if ($async.AsyncWaitHandle.WaitOne($script:NetTimeoutMs, $false) -and $client.Connected) {
                $client.EndConnect($async)
                $probeSw.Stop()
                $r.MsReachable   = $true
                $r.MsProbeMs     = [int]$probeSw.Elapsed.TotalMilliseconds
                $r.MsProbeResult = 'Connected'
            }
            else {
                $probeSw.Stop()
                $r.MsProbeMs     = $script:NetTimeoutMs
                $r.MsProbeResult = 'Timeout'
                $r.Findings += "Management server $($r.ManagementServer):$($r.ManagementServerPort) did not answer within $($script:NetTimeoutMs)ms -- server-side, network, or firewall; not fixable from this device"
            }
        }
        catch {
            $r.MsProbeMs = $UNKNOWN
            # Name resolution failure and connection refused are different problems;
            # keep the distinction rather than collapsing both to "unreachable".
            $r.MsProbeResult = if ($_.Exception.Message -match 'No such host|not known') { 'DnsFailure' } else { 'ConnectFailed' }
            $r.Findings += "Management server probe failed ($($r.MsProbeResult)) -- $($_.Exception.Message)"
        }
        finally {
            if ($client) { $client.Close() }
        }
    }
    else {
        $r.MsProbeMs     = $TIMEDOUT
        $r.MsProbeResult = 'TimedOut'
    }

    # -- Phase 5: configuration cache freshness --------------------------------
    if ($configDir -and (Test-Path -LiteralPath $configDir)) {
        $cfg = Get-ChildItem -Path $configDir -Filter 'OpsMgrConnector.Config.xml' -Recurse -File -ErrorAction SilentlyContinue |
               Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($cfg) {
            $r.ConfigAgeHours = [int][math]::Round(((Get-Date) - $cfg.LastWriteTime).TotalHours, 0)
            if ($r.ConfigAgeHours -gt $script:ConfigStaleHours) {
                $r.Findings += "Configuration cache is $($r.ConfigAgeHours)h old -- the agent is running on stale management pack configuration"
            }
        }
        else {
            $r.Findings += 'No OpsMgrConnector.Config.xml in the configuration cache -- the agent has no management pack configuration to run'
        }
    }
    elseif ($installDir) {
        $r.Findings += 'Connector Configuration Cache folder not present -- the agent has never received configuration from its management server'
    }

    # -- Phase 6: state folder and store database size -------------------------
    # FileSystemObject, not Get-ChildItem -Recurse. On a large Health Service State
    # the recursive enumeration alone can outlast this sensor's entire budget.
    if (-not $stateDir) {
        $r.StateFolderMB = $UNKNOWN
    }
    elseif (-not (Test-Path -LiteralPath $stateDir)) {
        $r.StateFolderMB = $NOTAPPL
        $r.Findings += 'Health Service State folder not found -- agent state has never been created, or the install is damaged'
    }
    elseif (Test-Budget) {
        $fso = $null
        try {
            $fso    = New-Object -ComObject Scripting.FileSystemObject
            $folder = $fso.GetFolder($stateDir)
            $r.StateFolderMB = [int][math]::Round($folder.Size / 1MB, 0)
        }
        catch {
            $r.StateFolderMB = $UNKNOWN
        }
        finally {
            if ($fso) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($fso) }
        }

        if ($r.StateFolderMB -gt $script:StateFolderWarnMB) {
            $r.Findings += "Health Service State is $($r.StateFolderMB)MB (threshold $($script:StateFolderWarnMB)MB) -- real capacity on a VDI or small-disk laptop"
        }
    }
    else {
        $r.StateFolderMB = $TIMEDOUT
    }

    if ($storeDb -and (Test-Path -LiteralPath $storeDb)) {
        $db = Get-Item -LiteralPath $storeDb -ErrorAction SilentlyContinue
        if ($db) {
            $r.StoreDbMB = [int][math]::Round($db.Length / 1MB, 0)
            if ($r.StoreDbMB -gt $script:StoreDbWarnMB) {
                # Growth here is usually backpressure, not corruption: the agent is
                # queueing data it cannot upload. Fix the upload path first.
                $r.Findings += "HealthServiceStore.edb is $($r.StoreDbMB)MB (threshold $($script:StoreDbWarnMB)MB) -- usually a symptom of the agent being unable to upload; confirm management server connectivity before flushing"
            }
        }
    }
    elseif ($stateDir) {
        $r.StoreDbMB = $NOTAPPL
        $r.Findings += 'HealthServiceStore.edb not found -- the agent has no state database'
    }

    # -- Phase 7: runtime footprint --------------------------------------------
    $agentProcs = @(Get-Process -Name 'HealthService', 'MonitoringHost' -ErrorAction SilentlyContinue)
    if ($agentProcs.Count -gt 0) {
        $ws = 0
        foreach ($p in $agentProcs) { $ws += $p.WorkingSet64 }
        $r.RuntimeMemoryMB     = [int][math]::Round($ws / 1MB, 0)
        $r.MonitoringHostCount = @($agentProcs | Where-Object { $_.Name -eq 'MonitoringHost' }).Count

        # Average CPU since process start, derived from TotalProcessorTime -- one
        # cheap read, no sampling interval. It is not an instantaneous figure, and a
        # long-running process will always look calm here.
        $cpuTotal = 0.0
        $counted  = 0
        foreach ($p in $agentProcs) {
            if ($p.StartTime) {
                $lifeSec = ((Get-Date) - $p.StartTime).TotalSeconds
                if ($lifeSec -gt 0) {
                    $cpuTotal += ($p.TotalProcessorTime.TotalSeconds / $lifeSec) * 100.0
                    $counted++
                }
            }
        }
        if ($counted -gt 0) {
            $r.RuntimeCpuPercent = [int][math]::Round($cpuTotal / [Environment]::ProcessorCount, 0)
        }

        if ($r.RuntimeMemoryMB -gt $script:RuntimeMemoryWarnMB) {
            $r.Findings += "Agent working set is $($r.RuntimeMemoryMB)MB (threshold $($script:RuntimeMemoryWarnMB)MB) across $($agentProcs.Count) process(es)"
        }
        if ($r.RuntimeCpuPercent -gt $script:RuntimeCpuWarnPercent) {
            $r.Findings += "Agent average CPU since start is $($r.RuntimeCpuPercent)% (threshold $($script:RuntimeCpuWarnPercent)%)"
        }
    }
    else {
        # Zero, not Unknown: the agent genuinely is not running. That is a real
        # measurement and the service-state deduction already accounts for it.
        $r.RuntimeMemoryMB     = 0
        $r.RuntimeCpuPercent   = 0
        $r.MonitoringHostCount = 0
    }

    # -- Phase 8: single pass over the Operations Manager log ------------------
    # One query, bucketed in memory. This is the most expensive phase in the file,
    # so it is budget-checked before it starts rather than after.
    if (Test-Budget) {
        $counts = @{}
        try {
            # LogName + StartTime only. Adding ProviderName or Id to the same
            # hashtable is the combination that throws a TERMINATING "parameter is
            # incorrect" on hosts where the provider is not registered -- straight
            # past -ErrorAction SilentlyContinue.
            $since  = (Get-Date).AddHours(-$script:EventLookbackHrs)
            $events = @(Get-WinEvent -FilterHashtable @{
                LogName   = 'Operations Manager'
                StartTime = $since
            } -MaxEvents $script:MaxEventsScanned -ErrorAction SilentlyContinue)

            # An empty result is still a readable log. A quiet agent is a healthy agent.
            $r.OpsLogAvailable = $true

            foreach ($e in $events) {
                $k = [string]$e.Id
                if ($counts.ContainsKey($k)) { $counts[$k]++ } else { $counts[$k] = 1 }
            }

            $sum = {
                param([int[]]$Ids)
                $t = 0
                foreach ($i in $Ids) {
                    $k = [string]$i
                    if ($counts.ContainsKey($k)) { $t += $counts[$k] }
                }
                return $t
            }

            $r.ConnectFailures24h   = & $sum @(20070, 21006)
            $r.AuthFailures24h      = & $sum @(20071)
            $r.NotRegistered24h     = & $sum @(21016)
            $r.UnloadedWorkflows24h = & $sum @(1103, 4001)
            $r.ScriptFailures24h    = & $sum @(1102, 21405)
        }
        catch {
            $r.OpsLogAvailable = $false
        }

        # ESENT store errors live in the Application log under their own provider,
        # not in Operations Manager -- a second, separately-guarded query.
        if (Test-Budget) {
            try {
                $esentEvents = @(Get-WinEvent -FilterHashtable @{
                    LogName      = 'Application'
                    ProviderName = 'ESENT'
                    StartTime    = (Get-Date).AddHours(-$script:EventLookbackHrs)
                    Id           = 477, 490, 623
                } -MaxEvents 200 -ErrorAction SilentlyContinue)

                # ESENT is used by many Windows components. Only errors naming the
                # agent's own database are ours.
                $r.StoreDbErrors24h = @($esentEvents | Where-Object {
                    $_.Message -match 'HealthServiceStore|Health Service State'
                }).Count
            }
            catch {
                $r.StoreDbErrors24h = $UNKNOWN
            }
        }
        else {
            $r.StoreDbErrors24h = $TIMEDOUT
        }

        if ($r.AuthFailures24h -gt 0) {
            $r.Findings += "$($r.AuthFailures24h) connector authentication failure(s) in $($script:EventLookbackHrs)h -- Kerberos/SPN or certificate trust, resolved on the management server not here"
        }
        if ($r.NotRegistered24h -gt 0) {
            $r.Findings += "$($r.NotRegistered24h) 'agent not registered' event(s) in $($script:EventLookbackHrs)h -- the management group is rejecting this agent's identity"
        }
        if ($r.ConnectFailures24h -ge $script:ConnectFailureWarnCount) {
            $r.Findings += "$($r.ConnectFailures24h) connector connect failure(s) in $($script:EventLookbackHrs)h"
        }
        if ($r.UnloadedWorkflows24h -ge $script:UnloadedWorkflowWarnCount) {
            $r.Findings += "$($r.UnloadedWorkflows24h) workflow(s) unloaded in $($script:EventLookbackHrs)h -- monitoring is silently incomplete"
        }
        if ($r.StoreDbErrors24h -gt 0) {
            $r.Findings += "$($r.StoreDbErrors24h) ESENT error(s) against the health service store in $($script:EventLookbackHrs)h -- state database corruption"
        }
    }
    else {
        foreach ($k in @('ConnectFailures24h','AuthFailures24h','NotRegistered24h',
                         'UnloadedWorkflows24h','ScriptFailures24h','StoreDbErrors24h')) {
            $r[$k] = $TIMEDOUT
        }
    }

    # -- Phase 9: channel certificate ------------------------------------------
    # Certificate-authenticated agents only (workgroup, DMZ, cross-forest). A
    # domain-joined agent uses Kerberos and legitimately has no channel certificate,
    # which is why the default here is Not applicable rather than Unknown.
    if (Test-Budget) {
        try {
            $chan = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Microsoft Operations Manager\3.0\Machine Settings' `
                        -Name 'ChannelCertificateSerialNumber' -ErrorAction SilentlyContinue

            if ($chan -and $chan.ChannelCertificateSerialNumber) {
                # Stored little-endian; reverse to match the certificate store's serial.
                $bytes = @($chan.ChannelCertificateSerialNumber)
                [array]::Reverse($bytes)
                $serial = (($bytes | ForEach-Object { '{0:X2}' -f $_ }) -join '')

                $cert = Get-ChildItem -Path 'Cert:\LocalMachine\My' -ErrorAction SilentlyContinue |
                        Where-Object { $_.SerialNumber -eq $serial } | Select-Object -First 1

                if ($cert) {
                    $r.CertExpiryDays = [int][math]::Round(($cert.NotAfter - (Get-Date)).TotalDays, 0)
                    if ($r.CertExpiryDays -lt 0) {
                        $r.CertProblem = $true
                        $r.Findings += "Channel certificate expired $([math]::Abs($r.CertExpiryDays)) day(s) ago -- the agent cannot authenticate; PKI-owned, reissue required"
                    }
                    elseif ($r.CertExpiryDays -lt $script:CertExpiryWarnDays) {
                        $r.CertProblem = $true
                        $r.Findings += "Channel certificate expires in $($r.CertExpiryDays) day(s) -- PKI-owned, renew before it lapses"
                    }
                }
                else {
                    $r.CertExpiryDays = $UNKNOWN
                    $r.CertProblem    = $true
                    $r.Findings += 'Channel certificate is configured but the matching certificate is not in LocalMachine\My -- the agent cannot authenticate'
                }
            }
        }
        catch {
            $r.CertExpiryDays = $UNKNOWN
        }
    }
    else {
        $r.CertExpiryDays = $TIMEDOUT
    }

    # -- Phase 10: time sync age -----------------------------------------------
    # Registry read of the last successful sync, not a skew measurement -- see
    # "NOT COLLECTED, AND WHY" above.
    try {
        $w32 = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Config' `
                   -Name 'LastKnownGoodTime' -ErrorAction SilentlyContinue
        if ($w32 -and $w32.LastKnownGoodTime) {
            $last = [DateTime]::FromFileTime([int64]$w32.LastKnownGoodTime)
            $r.TimeSyncAgeHours = [int][math]::Round(((Get-Date) - $last).TotalHours, 0)
            if ($r.TimeSyncAgeHours -gt $script:SyncStaleHours) {
                $r.Findings += "No successful time sync in $($r.TimeSyncAgeHours)h -- Kerberos to the management server fails outright past 300s of skew; see GenericTroubleshooting/TimeSyncHealth"
            }
        }
    }
    catch {
        $r.TimeSyncAgeHours = $UNKNOWN
    }

    # -- Phase 11: optional sub-services ---------------------------------------
    if (Get-Service -Name 'AdtAgent' -ErrorAction SilentlyContinue) { $r.AdtAgentPresent = $true }
    if ($installDir -and (Test-Path -LiteralPath (Join-Path $installDir 'APMDOTNETAgent'))) { $r.ApmPresent = $true }

    # -- Scoring ---------------------------------------------------------------
    # Deduction table mirrored from Invoke-AutoRemediateSCOMAgent.ps1, condition for
    # condition. Only a metric that was actually measured may deduct, which holds
    # because every sentinel is negative and every threshold comparison is against a
    # positive number -- an unmeasured or timed-out phase simply fails its test rather
    # than deducting. The two -ge 0 guards below are the exceptions, kept because the
    # sweep has them and this table must not drift from it.
    $score      = 100
    $deductions = @()

    $serviceHealthy = ($r.ServicePresent -and $r.ServiceStatus -eq 'Running' -and
                       $r.ServiceStartMode -notin @('Disabled', 'Manual'))

    if (-not $serviceHealthy) {
        $score -= 40; $deductions += @{ P = 40; R = 'HealthServiceStopped' }
    }
    # MsProbeResult is checked, not just MsReachable. The sweep can use the simpler
    # test because it always probes; here the probe can be skipped by the deadline,
    # and a probe that never ran must not be scored as a failed one -- that would turn
    # a slow device into a fabricated 25-point management server outage.
    if ($r.ManagementServer -and -not $r.MsReachable -and $r.MsProbeResult -ne 'TimedOut') {
        $score -= 25; $deductions += @{ P = 25; R = 'ManagementServerUnreachable' }
    }
    if ($r.NotRegistered24h -gt 0) {
        $score -= 25; $deductions += @{ P = 25; R = 'AgentNotRegistered' }
    }
    if ($r.ManagementGroupCount -eq 0) {
        $score -= 20; $deductions += @{ P = 20; R = 'NoManagementGroup' }
    }
    if ($r.AuthFailures24h -gt 0) {
        $score -= 20; $deductions += @{ P = 20; R = 'ConnectorAuthenticationFailure' }
    }
    if ($r.StoreDbErrors24h -gt 0) {
        $score -= 20; $deductions += @{ P = 20; R = 'HealthServiceStoreCorruption' }
    }
    if ($r.ConfigAgeHours -ge 0 -and $r.ConfigAgeHours -gt $script:ConfigStaleHours) {
        $score -= 15; $deductions += @{ P = 15; R = 'ConfigurationCacheStale' }
    }
    if ($r.RuntimeMemoryMB -gt $script:RuntimeMemoryWarnMB -or
        ($r.RuntimeCpuPercent -ge 0 -and $r.RuntimeCpuPercent -gt $script:RuntimeCpuWarnPercent)) {
        $score -= 15; $deductions += @{ P = 15; R = 'AgentRuntimeFootprintHigh' }
    }
    if ($r.CertProblem) {
        $score -= 15; $deductions += @{ P = 15; R = 'ChannelCertificateProblem' }
    }
    if ($r.TimeSyncAgeHours -gt $script:SyncStaleHours) {
        $score -= 15; $deductions += @{ P = 15; R = 'TimeSkew' }
    }
    if ($r.UnloadedWorkflows24h -ge $script:UnloadedWorkflowWarnCount) {
        $score -= 10; $deductions += @{ P = 10; R = 'WorkflowsUnloaded' }
    }
    if ($r.StateFolderMB -gt $script:StateFolderWarnMB) {
        $score -= 10; $deductions += @{ P = 10; R = 'HealthServiceStateOversized' }
    }
    if ($r.ManagementGroupCount -gt 1) {
        $score -= 5;  $deductions += @{ P = 5;  R = 'MultiHomedAgent' }
    }
    if ($r.ConnectFailures24h -ge $script:ConnectFailureWarnCount) {
        $score -= 5;  $deductions += @{ P = 5;  R = 'IntermittentConnectivity' }
    }

    if ($score -lt 0) { $score = 0 }

    $r.HealthScore  = $score
    $r.HealthReason = if ($deductions.Count -eq 0) { 'Healthy' }
                      else { ($deductions | Sort-Object { $_.P } -Descending | Select-Object -First 1).R }

    Write-Result
    return
}
catch {
    # Type-valid output on every path. A sensor that emits nothing is
    # indistinguishable from one that never ran.
    $r.HealthReason = 'CollectionError'
    $r.Findings    += "Collection failed: $($_.Exception.Message)"
    Write-Result
    return
}
