#Requires -Version 5.1
<#
.SYNOPSIS
    SCOMAgentResolutionWizard -- Operations Manager agent health checks and remediation.

.DESCRIPTION
    Runs an ordered sequence of System Center Operations Manager agent (HealthService /
    Microsoft Monitoring Agent) health checks and automatically executes the corresponding
    remediation for any step that fails. Fully self-contained -- no JSON, no UI, no external
    dependencies.

    14 steps: 1 HealthService Service State, 2 Startup Delay, 3 Management Group
    Registration, 4 Management Server Connectivity, 5 Configuration Cache Freshness,
    6 State Folder Size, 7 Health Service Store Database, 8 Agent Runtime Footprint,
    9 Connector Connectivity Failures, 10 Workflow Health, 11 Channel Certificate
    Health, 12 Agent Version, 13 Time Synchronisation Skew, 14 Optional Sub-services.

    Each step returns @{ Status = 'Passed'|'Warning'|'Failed'; Message = '...' } via the
    Res helper. ONLY steps 1 (start a stopped service) and 4 (flush DNS) remediate; every
    other step reports and names the Tier 2 spin-off that would act. That split is the
    whole design -- anything that deletes agent state, restarts the agent under a running
    workflow, or alters agent identity is detected here but remediated only by a
    separately-deployed, explicitly opted-in script.

    SCOPE -- AGENT SIDE ONLY
    This runs on the monitored endpoint and never touches a management server, gateway,
    or the operational database. Where a failure is server-side (agent not approved, SPN
    wrong, channel certificate expired, management server down) the step says so and takes
    no action. A device-side script cannot fix those, and pretending otherwise produces a
    green dashboard over a grey agent.

    RUNTIME GUARDRAILS
    - The 'Operations Manager' event log is read ONCE and bucketed in memory; steps 9 and
      10 read that shared result rather than issuing a query each.
    - Folder sizes use Scripting.FileSystemObject, never Get-ChildItem -Recurse.
    - Service start uses sc.exe (returns at START_PENDING) rather than Start-Service,
      which blocks for the full ~30s SCM timeout on a wedged agent.
    - CPU is derived from TotalProcessorTime over process lifetime -- an average since
      start, not an instantaneous figure, and labelled as such.
    - Get-WinEvent -FilterHashtable can throw a TERMINATING error even under
      -ErrorAction SilentlyContinue when a log or provider is absent, so the engine wraps
      every detection call and three steps carry their own inner try/catch for local
      recovery.

    >> Deployment guidance, the health-score reason table, sensor contract, VDI/golden-image
       notes, tunable reference and troubleshooting are in
       ApplicationSpecific/SCOM/README.md. Read it before deploying.

.NOTES
    Script Name  : Invoke-AutoRemediateSCOMAgent.ps1
    Version      : 1.0.0
    Architecture : x64
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-25
    Timeout      : 45 seconds (deploy with a 120 second UEM timeout)

    Environment variables:
      WhatIf = true    Dry run. Absent/unparseable => live run.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param()

$SCRIPT_VERSION = '1.0.0'
$RegPath        = 'HKLM:\Software\AirWatch\Extensions\SCOM'
$LogPath        = "$env:SystemRoot\Temp\UEM_AutoRemediateSCOMAgent.log"

# -- Tunables --
# Hard-coded deliberately: UEM variables are per-script-object, not per-assignment,
# so exposing these would give no real deployment flexibility. Fork the script
# object if a ring needs different values.
$StartupDelayWarnSeconds   = 300     # HealthService started this long after boot -> flag
$ConfigStaleHours          = 24      # Connector config cache untouched this long -> flag
$StateFolderWarnMB         = 1536    # Health Service State larger than this -> flag
$StoreDbWarnMB             = 768     # HealthServiceStore.edb larger than this -> flag
$RuntimeMemoryWarnMB       = 400     # HealthService + MonitoringHost working set -> flag
$RuntimeCpuWarnPercent     = 15      # Average CPU since start across agent processes
$ConnectFailureWarnCount   = 5       # Connector connect/auth failures in the window
$UnloadedWorkflowWarnCount = 3       # Unloaded workflow events in the window
$CertExpiryWarnDays        = 30      # Channel certificate expiring inside this window
$TimeSkewWarnSeconds       = 120     # Kerberos fails at 300; flag well before that
$SyncStaleHours            = 48      # No successful time sync in this window -> flag
$NetTimeoutMs              = 3000    # Socket timeout for the management server probe
$EventLookbackHours        = 24      # Event log analysis window
$MaxEventsScanned          = 2000    # Ceiling on events pulled in the single log pass

# -- WhatIf bridge --
# UEM cannot set $WhatIfPreference directly. Bridge it from an environment
# variable. Absent, empty, or unparseable => $false (live run).
$WhatIfPreference = $false
if ($env:WhatIf) {
    try   { $WhatIfPreference = [System.Convert]::ToBoolean($env:WhatIf) }
    catch { $WhatIfPreference = $false }
}

# -- Run header --
$RunEventId = ([Random]::new()).Next(1000, 9999)
Write-Host "[$RunEventId] Executing Invoke-AutoRemediateSCOMAgent, $SCRIPT_VERSION. Started @ '$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))'  WhatIf=$WhatIfPreference"
$HEAD = "`r`n[$RunEventId]"

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    # -WhatIf:$false so a dry run is still recorded; the log is evidence, not state.
    "[$timestamp] [$RunEventId] [$Level] $Message" |
        Out-File -FilePath $LogPath -Append -Encoding UTF8 -WhatIf:$false -ErrorAction SilentlyContinue
}

# -- Folder sizing --
# FSO computes subtree size natively. Get-ChildItem -Recurse is forbidden for
# sizing: unbounded runtime and it materialises a FileInfo per file.
# Compact result constructor. Every detection returns through this; the long form
# (return @{ Status = '...'; Message = '...' }) cost ~2.1KB of wrapper across 59
# call sites. Status is positional and unquoted: Res Warning "..."
function Res { param([string]$S, [string]$M) return @{ Status = $S; Message = $M } }
function Get-FolderSizeMB {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path) -or -not (Test-Path -LiteralPath $Path)) { return -1 }
    $sizeMB = -1
    $fso    = $null
    try {
        $fso    = New-Object -ComObject Scripting.FileSystemObject
        $folder = $fso.GetFolder($Path)
        $sizeMB = [math]::Round($folder.Size / 1MB, 1)
    }
    catch { $sizeMB = -1 }
    finally {
        if ($fso) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($fso) }
    }
    return $sizeMB
}

# -- Agent discovery --
$OmKeyRoot  = 'HKLM:\SOFTWARE\Microsoft\Microsoft Operations Manager\3.0'
$OmKeyRoot32 = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Microsoft Operations Manager\3.0'

$agentRoot  = $null
foreach ($candidate in @($OmKeyRoot, $OmKeyRoot32)) {
    if (Test-Path $candidate) { $agentRoot = $candidate; break }
}

$installDir = ''
if ($agentRoot) {
    $setup = Get-ItemProperty -Path (Join-Path $agentRoot 'Setup') -ErrorAction SilentlyContinue
    if ($setup -and $setup.InstallDirectory) { $installDir = [string]$setup.InstallDirectory }
}

$healthSvc = Get-Service -Name 'HealthService' -ErrorAction SilentlyContinue

# -- Guard clause --
# Nothing here is meaningful without an agent. Exit before the engine rather than
# reporting fourteen inapplicable steps.
if (-not $healthSvc -and -not $agentRoot) {
    Write-Output "$HEAD No Operations Manager agent present on this device. Nothing to process."
    Write-Log 'No SCOM agent detected. Exiting.'
    try {
        if (-not (Test-Path $RegPath)) { New-Item -Path $RegPath -Force -ErrorAction Stop -WhatIf:$false | Out-Null }
        Set-ItemProperty -Path $RegPath -Name 'AgentInstalled' -Value 0    -Type DWord  -ErrorAction Stop -WhatIf:$false
        Set-ItemProperty -Path $RegPath -Name 'HealthScore'    -Value '-1' -Type String -ErrorAction Stop -WhatIf:$false
        Set-ItemProperty -Path $RegPath -Name 'HealthReason'   -Value 'NoAgentInstalled' -Type String -ErrorAction Stop -WhatIf:$false
        Set-ItemProperty -Path $RegPath -Name 'Status'         -Value 'NotApplicable'    -Type String -ErrorAction Stop -WhatIf:$false
        Set-ItemProperty -Path $RegPath -Name 'LastRunTime'    -Value (Get-Date -Format 'o') -Type String -ErrorAction Stop -WhatIf:$false
    }
    catch { }
    exit 0
}

$StateDir  = if ($installDir) { Join-Path $installDir 'Health Service State' } else { '' }
$StoreDb   = if ($StateDir)   { Join-Path $StateDir 'Health Service Store\HealthServiceStore.edb' } else { '' }
$ConfigDir = if ($StateDir)   { Join-Path $StateDir 'Connector Configuration Cache' } else { '' }

Write-Log "Agent root: $agentRoot | InstallDir: $installDir | Service present: $([bool]$healthSvc)"

# -- Shared metrics (populated by detection, consumed by scoring) --
$Script:MsName            = ''
$Script:MsPort            = 5723
$Script:MsReachable       = $false
$Script:MgCount           = 0
$Script:ConfigAgeHours    = -1
$Script:StateFolderMB     = -1
$Script:StoreDbMB         = -1
$Script:StoreDbErrors     = -1
$Script:RuntimeMemoryMB   = -1
$Script:RuntimeCpuPercent = -1
$Script:MonitoringHostCount = -1
$Script:ConnectFailures   = -1
$Script:AuthFailures      = -1
$Script:NotRegistered     = -1
$Script:UnloadedWorkflows = -1
$Script:ScriptFailures    = -1
$Script:CertExpiryDays    = -1
$Script:CertProblem       = $false
$Script:AgentVersion      = ''
$Script:TimeSkewSeconds   = -1
$Script:SyncAgeHours      = -1
$Script:ServiceHealthy    = $false

# -- Single pass over the Operations Manager log --
# One query, bucketed in memory. Fourteen steps issuing their own Get-WinEvent
# would dominate the runtime budget on a busy endpoint.
$Script:OpsLogAvailable = $false
$Script:OpsEventCounts  = @{}
$since = (Get-Date).AddHours(-$EventLookbackHours)

try {
    # Deliberately LogName + StartTime only. Adding ProviderName/Id to the same
    # hashtable is the combination that throws "The parameter is incorrect" as a
    # terminating error on hosts where the provider is not registered.
    $opsEvents = @(Get-WinEvent -FilterHashtable @{
        LogName   = 'Operations Manager'
        StartTime = $since
    } -MaxEvents $MaxEventsScanned -ErrorAction SilentlyContinue)

    if ($opsEvents.Count -gt 0) {
        $Script:OpsLogAvailable = $true
        foreach ($e in $opsEvents) {
            $key = [string]$e.Id
            if ($Script:OpsEventCounts.ContainsKey($key)) { $Script:OpsEventCounts[$key]++ }
            else { $Script:OpsEventCounts[$key] = 1 }
        }
    }
    else {
        # An empty result is still a readable log -- a quiet agent is a healthy agent.
        $Script:OpsLogAvailable = $true
    }
    Write-Log "Operations Manager log: $($opsEvents.Count) event(s) in the last ${EventLookbackHours}h."
}
catch {
    $Script:OpsLogAvailable = $false
    Write-Log "Operations Manager log unavailable: $($_.Exception.Message)" -Level 'WARN'
}

function Get-OpsEventCount {
    param([int[]]$Id)
    $total = 0
    foreach ($i in $Id) {
        $key = [string]$i
        if ($Script:OpsEventCounts.ContainsKey($key)) { $total += $Script:OpsEventCounts[$key] }
    }
    return $total
}

# -- Step Definitions --
# Fields: Name, DetectionScript, and ResolutionScript where the step acts.
# Optional: Enabled = $false to ship a step disabled; ResolveOnWarning = $true
# to remediate on Warning as well as Failed. Execution order is array order.
$Steps = @(

    @{
        Name             = 'HealthService Service State'
        DetectionScript  = {
            $svc = Get-Service -Name 'HealthService' -ErrorAction SilentlyContinue
            if (-not $svc) {
                return Res Failed 'HealthService is not installed but agent registry keys exist -- the agent is partially installed or partially removed'
            }

            $cim       = Get-CimInstance -ClassName Win32_Service -Filter "Name='HealthService'" -ErrorAction SilentlyContinue
            $startMode = if ($cim) { $cim.StartMode } else { 'Unknown' }

            if ($svc.Status -ne 'Running') {
                return Res Failed "HealthService is $($svc.Status) (StartMode: $startMode) -- this device is grey in the console"
            }
            if ($startMode -eq 'Disabled' -or $startMode -eq 'Manual') {
                return Res Failed "HealthService running but StartMode is $startMode -- monitoring will not survive a reboot"
            }

            $Script:ServiceHealthy = $true
            return Res Passed "HealthService is Running (StartMode: $startMode)"
        }
        ResolutionScript = {
            # Never fight an in-progress agent install, upgrade, or repair.
            if (Get-Process -Name 'MOMAgentInstaller', 'setup' -ErrorAction SilentlyContinue) { return }

            if ($PSCmdlet.ShouldProcess('HealthService', 'Set start type to Automatic and start service')) {
                & sc.exe config HealthService start= auto | Out-Null
                # sc.exe start returns at START_PENDING. Start-Service would block for
                # the full SCM timeout (~30s) on a wedged agent and blow the budget.
                & sc.exe start HealthService | Out-Null
                Write-Log 'Issued start type change and start for HealthService.'
            }
        }
    },

    @{
        Name             = 'HealthService Startup Delay'
        # Informational -- the dependency chain is not safely auto-fixable
        DetectionScript  = {
            # Best-guess heuristic from already-resident data: compare process start
            # against last boot. No event log query, no added runtime.
            $proc = Get-Process -Name 'HealthService' -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $proc) {
                return Res Warning 'HealthService process not running -- startup delay not measurable'
            }

            $boot = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue).LastBootUpTime
            if (-not $boot) {
                return Res Warning 'Unable to read last boot time -- startup delay not measurable'
            }

            $delay = [math]::Round(($proc.StartTime - $boot).TotalSeconds)
            if ($delay -lt 0) {
                return Res Passed 'HealthService restarted since boot -- startup delay not applicable'
            }
            if ($delay -gt $StartupDelayWarnSeconds) {
                return Res Warning "HealthService started ${delay}s after boot (threshold ${StartupDelayWarnSeconds}s) -- check the WMI/RPC dependency chain; on VDI this is usually storage contention at boot storm"
            }
            return Res Passed "HealthService started ${delay}s after boot"
        }
    },

    @{
        Name             = 'Management Group Registration'
        # Approval and assignment are management server actions
        DetectionScript  = {
            if (-not $agentRoot) {
                return Res Failed 'Operations Manager registry root missing -- agent configuration is not readable'
            }

            $mgRoot = Join-Path $agentRoot 'Agent Management Groups'
            if (-not (Test-Path $mgRoot)) {
                return Res Failed 'No management group configured -- the agent has never been assigned to a management group'
            }

            $groups = @(Get-ChildItem -Path $mgRoot -ErrorAction SilentlyContinue)
            $Script:MgCount = $groups.Count

            if ($groups.Count -eq 0) {
                return Res Failed 'Management group key exists but contains no groups -- agent is unassigned'
            }

            $parents = @()
            foreach ($g in $groups) {
                $phs = Get-ChildItem -Path (Join-Path $g.PSPath 'Parent Health Services') -ErrorAction SilentlyContinue
                foreach ($p in $phs) {
                    $props = Get-ItemProperty -Path $p.PSPath -ErrorAction SilentlyContinue
                    if ($props -and $props.NetworkName) {
                        $parents += [PSCustomObject]@{
                            Group   = $g.PSChildName
                            Network = [string]$props.NetworkName
                            Port    = if ($props.Port) { [int]$props.Port } else { 5723 }
                        }
                    }
                }
            }

            if ($parents.Count -eq 0) {
                return Res Failed "Management group(s) '$(($groups | ForEach-Object { $_.PSChildName }) -join ', ')' configured but no parent management server assigned -- the agent was never approved, or its assignment was removed server-side"
            }

            # First parent is the primary; the rest are failover.
            $Script:MsName = $parents[0].Network
            $Script:MsPort = $parents[0].Port

            if ($groups.Count -gt 1) {
                # Multi-homing is legitimate, but each management group runs its own
                # full workflow set. On a laptop or a VDI session that is doubled
                # CPU, memory, and disk for the same monitoring.
                return Res Warning "Agent is multi-homed to $($groups.Count) management groups ($(($groups | ForEach-Object { $_.PSChildName }) -join ', ')) -- every workflow set runs once per group; confirm this is intended on an end-user device"
            }

            $failover = if ($parents.Count -gt 1) { ", $($parents.Count - 1) failover" } else { ', no failover configured' }
            return Res Passed "Management group '$($parents[0].Group)' via $($Script:MsName):$($Script:MsPort)$failover"
        }
    },

    @{
        Name             = 'Management Server Connectivity'
        DetectionScript  = {
            if (-not $Script:MsName) {
                return Res Warning 'No management server assigned (see step 3) -- connectivity not testable'
            }

            $port = if ($Script:MsPort) { $Script:MsPort } else { 5723 }

            # Time-boxed socket probe. WaitOne() alone is NOT sufficient: it also
            # returns true when the connect completed with a refusal (RST returns
            # instantly). EndConnect() throws in that case, which is what actually
            # distinguishes reachable from refused.
            $tcp = New-Object System.Net.Sockets.TcpClient
            try {
                $ar = $tcp.BeginConnect($Script:MsName, $port, $null, $null)
                if ($ar.AsyncWaitHandle.WaitOne($NetTimeoutMs, $false)) {
                    $tcp.EndConnect($ar)
                    if ($tcp.Connected) {
                        $Script:MsReachable = $true
                        return Res Passed "Management server reachable: $($Script:MsName):$port"
                    }
                }
            }
            catch { }
            finally { $tcp.Close() }

            return Res Failed "Management server unreachable on port ${port}: $($Script:MsName) -- expected off-corp without VPN; if the device is on-network this is a name resolution, firewall, or management server fault and is not fixable from the endpoint"
        }
        ResolutionScript = {
            # Local-side fix only. A genuine management server outage is server-side
            # and is reported, not fixed. A stale DNS record for a decommissioned or
            # re-addressed MS is the one endpoint-owned cause worth clearing.
            if ($PSCmdlet.ShouldProcess('DNS client', 'Flush resolver cache')) {
                & ipconfig /flushdns | Out-Null
                Write-Log 'Flushed resolver cache after a failed management server probe.'
            }
        }
    },

    @{
        Name             = 'Configuration Cache Freshness'
        # Report only -- flushing forces a full re-download (see spin-off)
        DetectionScript  = {
            if (-not $ConfigDir -or -not (Test-Path -LiteralPath $ConfigDir)) {
                return Res Warning 'Connector Configuration Cache folder not present -- the agent has never received configuration from its management server'
            }

            $config = Get-ChildItem -Path $ConfigDir -Filter 'OpsMgrConnector.Config.xml' -Recurse -File -ErrorAction SilentlyContinue |
                      Sort-Object LastWriteTime -Descending | Select-Object -First 1

            if (-not $config) {
                return Res Warning 'No OpsMgrConnector.Config.xml found in the configuration cache -- agent has no management pack configuration to run'
            }

            $Script:ConfigAgeHours = [math]::Round(((Get-Date) - $config.LastWriteTime).TotalHours, 1)

            if ($Script:ConfigAgeHours -gt $ConfigStaleHours) {
                return Res Warning "Configuration cache last updated $($Script:ConfigAgeHours)h ago (threshold ${ConfigStaleHours}h) -- agent may be running stale management packs; confirm step 4 first, then consider Invoke-AutoRemediateSCOMHealthServiceCache.ps1"
            }
            return Res Passed "Configuration cache updated $($Script:ConfigAgeHours)h ago"
        }
    },

    @{
        Name             = 'Health Service State Folder Size'
        # Report only -- see spin-off script
        DetectionScript  = {
            if (-not $StateDir -or -not (Test-Path -LiteralPath $StateDir)) {
                return Res Warning 'Health Service State folder not found -- agent state has never been created, or the install is damaged'
            }

            $Script:StateFolderMB = Get-FolderSizeMB -Path $StateDir
            if ($Script:StateFolderMB -lt 0) {
                return Res Warning 'Health Service State folder size could not be measured'
            }

            if ($Script:StateFolderMB -gt $StateFolderWarnMB) {
                return Res Warning "Health Service State is $($Script:StateFolderMB)MB (threshold ${StateFolderWarnMB}MB) -- on a VDI or small-disk laptop this is real capacity; deploy Invoke-AutoRemediateSCOMHealthServiceCache.ps1 to a targeted ring to reclaim"
            }
            return Res Passed "Health Service State is $($Script:StateFolderMB)MB"
        }
    },

    @{
        Name             = 'Health Service Store Database'
        # Report only -- see spin-off script
        DetectionScript  = {
            $dbNote = 'not measurable'
            if ($StoreDb -and (Test-Path -LiteralPath $StoreDb)) {
                $Script:StoreDbMB = [math]::Round((Get-Item -LiteralPath $StoreDb -ErrorAction SilentlyContinue).Length / 1MB, 1)
                $dbNote = "$($Script:StoreDbMB)MB"
            }

            # ESENT errors are the authoritative corruption signal for the agent's
            # eSENT-backed store. Own try/catch: ProviderName + Id + StartTime in one
            # filter hashtable is precisely the combination that can throw a
            # terminating error when the provider is not registered on this build.
            try {
                $esent = @(Get-WinEvent -FilterHashtable @{
                    LogName      = 'Application'
                    ProviderName = 'ESENT'
                    Id           = 477, 490, 623
                    StartTime    = (Get-Date).AddHours(-$EventLookbackHours)
                } -MaxEvents 200 -ErrorAction SilentlyContinue)

                # Scope to the agent's own store; ESENT is shared with other products.
                $Script:StoreDbErrors = @($esent | Where-Object {
                    $_.Message -match 'HealthServiceStore|Health Service State'
                }).Count
            }
            catch {
                $Script:StoreDbErrors = -1
                Write-Log "ESENT event query failed: $($_.Exception.Message)" -Level 'WARN'
            }

            if ($Script:StoreDbErrors -gt 0) {
                return Res Warning "$($Script:StoreDbErrors) ESENT error(s) against the Health Service Store in the last ${EventLookbackHours}h (database $dbNote) -- the store is damaged and will not self-repair; deploy Invoke-AutoRemediateSCOMHealthServiceCache.ps1"
            }

            if ($Script:StoreDbMB -gt $StoreDbWarnMB) {
                return Res Warning "HealthServiceStore.edb is $($Script:StoreDbMB)MB (threshold ${StoreDbWarnMB}MB) -- usually a symptom of the agent being unable to upload, so confirm steps 4 and 9 before flushing"
            }

            if ($Script:StoreDbMB -lt 0) {
                return Res Warning 'HealthServiceStore.edb not found -- the agent has no state database'
            }
            return Res Passed "HealthServiceStore.edb is $dbNote, no ESENT errors in the last ${EventLookbackHours}h"
        }
    },

    @{
        Name             = 'Agent Runtime Footprint'
        # Report only -- see spin-off script
        DetectionScript  = {
            $procs = @(Get-Process -Name 'HealthService', 'MonitoringHost' -ErrorAction SilentlyContinue)
            if ($procs.Count -eq 0) {
                return Res Warning 'No agent processes running -- see step 1'
            }

            $Script:MonitoringHostCount = @($procs | Where-Object { $_.ProcessName -eq 'MonitoringHost' }).Count
            $Script:RuntimeMemoryMB     = [math]::Round((($procs | Measure-Object -Property WorkingSet64 -Sum).Sum) / 1MB)

            # Average CPU since process start. A single cheap read rather than a
            # sampling interval -- it will not catch a spike, and it is not meant to.
            # Sustained-load confirmation is the spin-off script's job.
            $cores = [int](Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue).NumberOfLogicalProcessors
            if ($cores -lt 1) { $cores = 1 }

            $cpuSeconds = 0.0
            $lifetime   = 0.0
            foreach ($p in $procs) {
                try {
                    $cpuSeconds += $p.TotalProcessorTime.TotalSeconds
                    $span = ((Get-Date) - $p.StartTime).TotalSeconds
                    if ($span -gt $lifetime) { $lifetime = $span }
                }
                catch { }
            }
            if ($lifetime -gt 0) {
                $Script:RuntimeCpuPercent = [math]::Round(($cpuSeconds / $lifetime / $cores) * 100, 1)
            }

            $detail = "$($procs.Count) process(es) ($($Script:MonitoringHostCount) MonitoringHost), $($Script:RuntimeMemoryMB)MB working set, $($Script:RuntimeCpuPercent)% average CPU since start"

            if ($Script:RuntimeMemoryMB -gt $RuntimeMemoryWarnMB -or
                ($Script:RuntimeCpuPercent -ge 0 -and $Script:RuntimeCpuPercent -gt $RuntimeCpuWarnPercent)) {
                return Res Warning "Agent runtime footprint is high: $detail (thresholds ${RuntimeMemoryWarnMB}MB / ${RuntimeCpuWarnPercent}%) -- this is felt directly by the user on a laptop or shared VDI host; deploy Invoke-AutoRemediateSCOMMonitoringHost.ps1 to confirm and recycle"
            }
            return Res Passed "Agent runtime footprint normal: $detail"
        }
    },

    @{
        Name             = 'Connector Connectivity Failures'
        # Report only -- every cause here is server-side or PKI
        DetectionScript  = {
            if (-not $Script:OpsLogAvailable) {
                return Res Warning 'Operations Manager event log is not readable -- connector failure history unavailable'
            }

            # 21006/21001 = could not connect (network path, port, name resolution)
            # 20070/20071 = connected then authentication failed (certificate, SPN, Kerberos)
            # 21016       = no failover hosts available (agent not approved / assignment removed)
            $Script:ConnectFailures = Get-OpsEventCount -Id 21006, 21001
            $Script:AuthFailures    = Get-OpsEventCount -Id 20070, 20071
            $Script:NotRegistered   = Get-OpsEventCount -Id 21016
            $healthy                = Get-OpsEventCount -Id 20057, 21024

            $total = $Script:ConnectFailures + $Script:AuthFailures + $Script:NotRegistered

            if ($Script:NotRegistered -gt 0) {
                return Res Warning "$($Script:NotRegistered) event(s) 21016 in the last ${EventLookbackHours}h -- the management server is refusing this agent (pending approval, deleted from the console, or a duplicate identity from a cloned image). SERVER-SIDE: an administrator must approve or delete-and-reinstall; on a confirmed clone use Invoke-AutoRemediateSCOMClonedIdentity.ps1"
            }
            if ($Script:AuthFailures -gt 0) {
                return Res Warning "$($Script:AuthFailures) authentication failure(s) (20070/20071) in the last ${EventLookbackHours}h -- channel certificate, SPN, or Kerberos trust. SERVER-SIDE/PKI: not fixable from the endpoint; see step 11 and step 13"
            }
            if ($Script:ConnectFailures -ge $ConnectFailureWarnCount) {
                return Res Warning "$($Script:ConnectFailures) connection failure(s) (21006/21001) in the last ${EventLookbackHours}h (threshold ${ConnectFailureWarnCount}) -- normal for a laptop that roams off-corp; investigate only if the device is consistently on-network"
            }
            if ($total -eq 0 -and $healthy -gt 0) {
                return Res Passed "No connector failures in the last ${EventLookbackHours}h ($healthy successful connection event(s))"
            }
            return Res Passed "$total connector failure(s) in the last ${EventLookbackHours}h, below threshold"
        }
    },

    @{
        Name             = 'Workflow Health'
        # Report only -- broken workflows are a management pack problem
        DetectionScript  = {
            if (-not $Script:OpsLogAvailable) {
                return Res Warning 'Operations Manager event log is not readable -- workflow history unavailable'
            }

            # 1103/1102 = workflow unloaded after repeated failure
            # 4001/21405 = script/command workflow runtime failure
            # 7016/7017  = RunAs account could not log on
            $Script:UnloadedWorkflows = Get-OpsEventCount -Id 1103, 1102
            $Script:ScriptFailures    = Get-OpsEventCount -Id 4001, 21405
            $runAsFailures            = Get-OpsEventCount -Id 7016, 7017

            if ($runAsFailures -gt 0) {
                return Res Warning "$runAsFailures RunAs logon failure(s) (7016/7017) in the last ${EventLookbackHours}h -- a RunAs account in the management group has an expired password or lacks 'Log on as a service' here. SERVER-SIDE: RunAs configuration is owned by the management group"
            }
            if ($Script:UnloadedWorkflows -ge $UnloadedWorkflowWarnCount) {
                return Res Warning "$($Script:UnloadedWorkflows) workflow(s) unloaded (1103/1102) in the last ${EventLookbackHours}h (threshold ${UnloadedWorkflowWarnCount}) -- the agent is running but silently not monitoring what those workflows covered; report the rule/monitor names from the events to the management pack owner"
            }
            if ($Script:ScriptFailures -gt 0) {
                return Res Warning "$($Script:ScriptFailures) script workflow failure(s) (4001/21405) in the last ${EventLookbackHours}h -- a management pack script is erroring on this device; frequently the cause of high MonitoringHost CPU in step 8"
            }
            return Res Passed "No unloaded workflows or script failures in the last ${EventLookbackHours}h"
        }
    },

    @{
        Name             = 'Channel Certificate Health'
        # Informational -- certificate renewal is a PKI action
        DetectionScript  = {
            $machineSettings = Get-ItemProperty -Path (Join-Path $agentRoot 'Machine Settings') -ErrorAction SilentlyContinue
            $serial = if ($machineSettings) { $machineSettings.ChannelCertificateSerialNumber } else { $null }

            if (-not $serial) {
                # Domain-joined agents authenticate with Kerberos and legitimately
                # have no channel certificate. Absence is not a fault.
                return Res Passed 'No channel certificate configured (expected for Kerberos/domain-authenticated agents)'
            }

            # The registry stores the serial as a reversed byte array on every build
            # seen in the field, but treat a string value as already-formatted rather
            # than throwing the whole step away on an unexpected type.
            $serialHex = ''
            if ($serial -is [byte[]]) {
                $bytes = [byte[]]::new($serial.Length)
                [array]::Copy($serial, $bytes, $serial.Length)
                [array]::Reverse($bytes)
                $serialHex = (($bytes | ForEach-Object { '{0:X2}' -f $_ }) -join '')
            }
            else {
                $serialHex = ([string]$serial).Replace(' ', '').ToUpperInvariant()
            }

            if (-not $serialHex) {
                return Res Warning 'Channel certificate is configured but its serial number could not be read from the registry'
            }

            $cert = Get-ChildItem -Path 'Cert:\LocalMachine\My' -ErrorAction SilentlyContinue |
                    Where-Object { $_.SerialNumber -eq $serialHex } | Select-Object -First 1

            if (-not $cert) {
                $Script:CertProblem = $true
                return Res Failed "Channel certificate serial $serialHex is configured but no matching certificate exists in LocalMachine\My -- the agent cannot authenticate. PKI: re-issue and re-import with MOMCertImport"
            }

            $Script:CertExpiryDays = [math]::Round(($cert.NotAfter - (Get-Date)).TotalDays)

            if ($Script:CertExpiryDays -lt 0) {
                $Script:CertProblem = $true
                return Res Failed "Channel certificate expired $([math]::Abs($Script:CertExpiryDays)) day(s) ago ($($cert.Subject)) -- PKI action required"
            }
            if ($Script:CertExpiryDays -lt $CertExpiryWarnDays) {
                $Script:CertProblem = $true
                return Res Warning "Channel certificate expires in $($Script:CertExpiryDays) day(s) on $($cert.NotAfter.ToString('yyyy-MM-dd')) -- PKI action required before it lapses"
            }
            return Res Passed "Channel certificate valid for $($Script:CertExpiryDays) more day(s)"
        }
    },

    @{
        Name             = 'Agent Version'
        # Informational -- agent upgrade is push-managed from the management server
        DetectionScript  = {
            $setup = Get-ItemProperty -Path (Join-Path $agentRoot 'Setup') -ErrorAction SilentlyContinue
            if (-not $setup -or -not $setup.CurrentVersion) {
                # Some builds expose ProductVersion instead of CurrentVersion.
                $Script:AgentVersion = if ($setup -and $setup.ProductVersion) { [string]$setup.ProductVersion } else { '' }
            }
            else {
                $Script:AgentVersion = [string]$setup.CurrentVersion
            }

            if (-not $Script:AgentVersion -and $installDir) {
                $exe = Join-Path $installDir 'HealthService.exe'
                if (Test-Path -LiteralPath $exe) {
                    $Script:AgentVersion = (Get-Item -LiteralPath $exe -ErrorAction SilentlyContinue).VersionInfo.FileVersion
                }
            }

            if (-not $Script:AgentVersion) {
                return Res Warning 'Agent version could not be determined'
            }
            return Res Passed "Agent version $($Script:AgentVersion) -- compare against the management group target; upgrades are push-managed from the management server"
        }
    },

    @{
        Name             = 'Time Synchronisation Skew'
        # Report only -- time service repair has its own solution
        DetectionScript  = {
            # Local read only. Kerberos authentication to the management server fails
            # outright past 300 seconds of skew, which surfaces as step 9's 20070.
            # No network probe here -- a stripchart against a DC would cost seconds.
            $status = & w32tm.exe /query /status 2>&1
            if ($LASTEXITCODE -ne 0 -or -not $status) {
                return Res Warning 'Windows Time service did not respond to a status query -- skew unknown; see GenericTroubleshooting/TimeSyncHealth'
            }

            $text = ($status | Out-String)

            if ($text -match 'Phase Offset:\s*(-?[\d\.]+)s') {
                $Script:TimeSkewSeconds = [math]::Round([math]::Abs([double]$matches[1]), 1)
            }
            if ($text -match 'Last Successful Sync Time:\s*(.+)') {
                $syncRaw = $matches[1].Trim()
                $parsed  = [datetime]::MinValue
                if ([datetime]::TryParse($syncRaw, [ref]$parsed)) {
                    $Script:SyncAgeHours = [math]::Round(((Get-Date) - $parsed).TotalHours, 1)
                }
            }

            if ($Script:TimeSkewSeconds -ge 0 -and $Script:TimeSkewSeconds -gt $TimeSkewWarnSeconds) {
                return Res Warning "Clock offset is $($Script:TimeSkewSeconds)s (threshold ${TimeSkewWarnSeconds}s) -- Kerberos to the management server fails outright past 300s, which appears as authentication failures in step 9"
            }
            if ($Script:SyncAgeHours -ge 0 -and $Script:SyncAgeHours -gt $SyncStaleHours) {
                return Res Warning "Last successful time sync was $($Script:SyncAgeHours)h ago (threshold ${SyncStaleHours}h) -- offset will drift into Kerberos failure territory; see GenericTroubleshooting/TimeSyncHealth"
            }
            return Res Passed "Clock offset $($Script:TimeSkewSeconds)s, last sync $($Script:SyncAgeHours)h ago"
        }
    },

    @{
        Name             = 'Optional Agent Sub-services'
        # Report only -- disabling a sub-service is a monitoring design decision
        DetectionScript  = {
            $running = @()

            # Audit Collection forwarding. On a desktop or VDI session this ships
            # every security event off-box; if nobody asked for it, it is pure cost.
            $adt = Get-Service -Name 'AdtAgent' -ErrorAction SilentlyContinue
            if ($adt -and $adt.Status -eq 'Running') { $running += 'AdtAgent (audit collection forwarding)' }

            # .NET APM. It injects a profiler into monitored processes -- valuable on
            # an application server, an unnecessary risk and overhead on a client.
            $apm = Get-Service -Name 'System Center Management APM' -ErrorAction SilentlyContinue
            if ($apm -and $apm.Status -eq 'Running') { $running += 'System Center Management APM (.NET profiler injection)' }

            if ($running.Count -eq 0) {
                return Res Passed 'No optional agent sub-services running'
            }

            $isClient = $true
            $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
            if ($os -and $os.ProductType -ne 1) { $isClient = $false }

            if ($isClient) {
                return Res Warning "Optional sub-service(s) running on a client OS: $($running -join ', ') -- these are server-oriented features and are avoidable overhead on an end-user or VDI device; confirm they are intended before disabling"
            }
            return Res Passed "Optional sub-service(s) running: $($running -join ', ')"
        }
    }
)

# -- Execution Engine --
# Execution order is array order. A step may still be shipped disabled by adding
# Enabled = $false to its definition; absent means enabled.
$activeSteps = @($Steps | Where-Object { -not $_.ContainsKey('Enabled') -or $_.Enabled })

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

Write-Host ''
Write-Host "`n-- SCOMAgentResolutionWizard -------------------------------------" -ForegroundColor Cyan
Write-Host "   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')   Steps: $($activeSteps.Count)"
Write-Host '----------------------------------------------------------------' -ForegroundColor Cyan

$stepIndex = 0
foreach ($step in $activeSteps) {

    $stepIndex++
    $status     = 'Failed'
    $message    = 'Detection script did not return a result.'
    $remediated = $false
    $remError   = ''

    # -- Detection --
    # A thrown detection is a step failure, not a script failure.
    try {
        $result  = & $step.DetectionScript
        $status  = $result.Status
        $message = $result.Message
    }
    catch {
        $status  = 'Failed'
        $message = "Detection exception: $($_.Exception.Message)"
    }

    # -- Remediation --
    $shouldRemediate = ($status -eq 'Failed') -or
                       ($status -eq 'Warning' -and $step.ResolveOnWarning)

    if ($shouldRemediate -and $step.ResolutionScript) {
        try {
            & $step.ResolutionScript | Out-Null
            $remediated = $true
        }
        catch {
            $remError = $_.Exception.Message
        }
    }

    # -- Output --
    $color = switch ($status) {
        'Passed'  { 'Green'  }
        'Warning' { 'Yellow' }
        'Failed'  { 'Red'    }
        default   { 'White'  }
    }
    $remNote = if ($remediated)   { '  -> Remediation ran' }
               elseif ($remError) { "  -> Remediation ERROR: $remError" }
               else               { '' }

    Write-Host "`n  [$($status.PadRight(7))] $($step.Name): $message$remNote" -ForegroundColor $color
    Write-Log "[$status] $($step.Name): $message$remNote"

    $results.Add([PSCustomObject]@{
        Order      = $stepIndex
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

Write-Host "`n----------------------------------------------------------------" -ForegroundColor Cyan
Write-Host "  Passed: $passed  |  Warnings: $warnings  |  Failed: $failed  |  Remediations run: $remCount"
Write-Host "`n----------------------------------------------------------------" -ForegroundColor Cyan
Write-Host ''

# -- Health score --
# Computed once here so every sensor reading agrees on a single value. Modelled on
# Invoke-VpnStateCollection.ps1: deduction list, largest single deduction becomes
# the reported reason. A score of -1 means no agent installed and is handled by the
# guard clause above -- it is deliberately distinct from 0, which means an agent is
# present and comprehensively broken.
$healthScore = 100
$deductions  = @()

# Deduction table. Every rule is evaluated; the largest single deduction becomes the
# reported HealthReason. Sentinels are negative and every threshold is positive, so an
# unmeasured metric simply fails its test -- except ConfigAgeHours and RuntimeCpuPercent,
# which carry explicit -ge 0 guards because -1 would otherwise pass their comparison.
$DeductionRules = @(
    @{ Points = 40; Reason = 'HealthServiceStopped'; Test = { -not $Script:ServiceHealthy } }
    @{ Points = 25; Reason = 'ManagementServerUnreachable'; Test = { $Script:MsName -and -not $Script:MsReachable } }
    @{ Points = 25; Reason = 'AgentNotRegistered'; Test = { $Script:NotRegistered -gt 0 } }
    @{ Points = 20; Reason = 'NoManagementGroup'; Test = { $Script:MgCount -eq 0 } }
    @{ Points = 20; Reason = 'ConnectorAuthenticationFailure'; Test = { $Script:AuthFailures -gt 0 } }
    @{ Points = 20; Reason = 'HealthServiceStoreCorruption'; Test = { $Script:StoreDbErrors -gt 0 } }
    @{ Points = 15; Reason = 'ConfigurationCacheStale'; Test = { $Script:ConfigAgeHours -ge 0 -and $Script:ConfigAgeHours -gt $ConfigStaleHours } }
    @{ Points = 15; Reason = 'AgentRuntimeFootprintHigh'; Test = { $Script:RuntimeMemoryMB -gt $RuntimeMemoryWarnMB -or ($Script:RuntimeCpuPercent -ge 0 -and $Script:RuntimeCpuPercent -gt $RuntimeCpuWarnPercent) } }
    @{ Points = 15; Reason = 'ChannelCertificateProblem'; Test = { $Script:CertProblem } }
    @{ Points = 15; Reason = 'TimeSkew'; Test = { $Script:TimeSkewSeconds -ge 0 -and $Script:TimeSkewSeconds -gt $TimeSkewWarnSeconds } }
    @{ Points = 10; Reason = 'WorkflowsUnloaded'; Test = { $Script:UnloadedWorkflows -ge $UnloadedWorkflowWarnCount } }
    @{ Points = 10; Reason = 'HealthServiceStateOversized'; Test = { $Script:StateFolderMB -gt $StateFolderWarnMB } }
    @{ Points = 5; Reason = 'MultiHomedAgent'; Test = { $Script:MgCount -gt 1 } }
    @{ Points = 5; Reason = 'IntermittentConnectivity'; Test = { $Script:ConnectFailures -ge $ConnectFailureWarnCount } }
)

foreach ($rule in $DeductionRules) {
    if (& $rule.Test) {
        $healthScore -= $rule.Points
        $deductions  += @{ Points = $rule.Points; Reason = $rule.Reason }
    }
}
if ($healthScore -lt 0) { $healthScore = 0 }

$healthReason = if ($deductions.Count -eq 0) { 'Healthy' }
                else { ($deductions | Sort-Object { $_.Points } -Descending | Select-Object -First 1).Reason }

Write-Output "$HEAD Health score: $healthScore ($healthReason)"
Write-Log "Health score: $healthScore | Reason: $healthReason"

# -- Persist results for DEX sensors --
# Numerics are stored as String, not DWORD: several carry -1 for "not measured",
# and a DWORD reads that back as 4294967295.
try {
    if (-not (Test-Path $RegPath)) { New-Item -Path $RegPath -Force -ErrorAction Stop -WhatIf:$false | Out-Null }

    $overall = if ($failed -gt 0) { 'Failed' } elseif ($warnings -gt 0) { 'Warning' } else { 'Passed' }

    $values = [ordered]@{
        Status                 = $overall
        LastRunTime            = (Get-Date -Format 'o')
        ScriptVersion          = $SCRIPT_VERSION
        HealthScore            = [string]$healthScore
        HealthReason           = $healthReason
        AgentVersion           = $Script:AgentVersion
        ManagementServer       = $Script:MsName
        ManagementGroupCount   = [string]$Script:MgCount
        ConfigAgeHours         = [string]$Script:ConfigAgeHours
        StateFolderMB          = [string]$Script:StateFolderMB
        StoreDbMB              = [string]$Script:StoreDbMB
        StoreDbErrors24h       = [string]$Script:StoreDbErrors
        RuntimeMemoryMB        = [string]$Script:RuntimeMemoryMB
        RuntimeCpuPercent      = [string]$Script:RuntimeCpuPercent
        MonitoringHostCount    = [string]$Script:MonitoringHostCount
        ConnectFailures24h     = [string]$Script:ConnectFailures
        AuthFailures24h        = [string]$Script:AuthFailures
        NotRegistered24h       = [string]$Script:NotRegistered
        UnloadedWorkflows24h   = [string]$Script:UnloadedWorkflows
        ScriptFailures24h      = [string]$Script:ScriptFailures
        CertExpiryDays         = [string]$Script:CertExpiryDays
        TimeSkewSeconds        = [string]$Script:TimeSkewSeconds
        Passed                 = [string]$passed
        Warnings               = [string]$warnings
        Failed                 = [string]$failed
        RemediationsRun        = [string]$remCount
    }

    foreach ($name in $values.Keys) {
        Set-ItemProperty -Path $RegPath -Name $name -Value $values[$name] -Type String -ErrorAction Stop -WhatIf:$false
    }

    Set-ItemProperty -Path $RegPath -Name 'AgentInstalled'  -Value 1 -Type DWord -ErrorAction Stop -WhatIf:$false
    Set-ItemProperty -Path $RegPath -Name 'MsReachable'     -Value ([int]$Script:MsReachable) -Type DWord -ErrorAction Stop -WhatIf:$false
    Set-ItemProperty -Path $RegPath -Name 'ServiceRunning'  -Value ([int]$Script:ServiceHealthy) -Type DWord -ErrorAction Stop -WhatIf:$false

    Write-Log "Results cached to $RegPath"
}
catch {
    Write-Log "Failed to cache results: $($_.Exception.Message)" -Level 'ERROR'
}

if ($failed -gt 0) { exit 1 }
exit 0
