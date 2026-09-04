#Requires -Version 5.1
<#
.SYNOPSIS
    SCOMAgentResolutionWizard Part 1 of 3 -- connectivity and registration checks.

.DESCRIPTION
    Steps 1-5 of the Operations Manager agent health sweep. Split into three UEM script
    objects because the combined sweep is 48,336 characters against a 32,767 limit.

      1 HealthService Service State      AUTO -- sc.exe config/start
      2 HealthService Startup Delay      report
      3 Management Group Registration    report
      4 Management Server Connectivity   AUTO -- flush DNS only
      5 Configuration Cache Freshness    report

    Writes its metrics to HKLM:\Software\AirWatch\Extensions\SCOM plus a Part1RunTime
    marker. It does NOT compute the health score -- Part 3 does that, after reading back
    what Parts 1 and 2 cached. Deploy all three; Part 3 must run last.

    >> Deployment, the reason table, sensor contract and tunables are in
       ApplicationSpecific/SCOM/README.md. Read it before deploying.

.NOTES
    Script Name  : Invoke-AutoRemediateSCOMAgentPart1.ps1
    Version      : 1.1.0
    Architecture : x64
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-25
    Timeout      : 20 seconds (deploy with a 60 second UEM timeout)

    Environment variables:
      WhatIf = true    Dry run. Absent/unparseable => live run.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>
function Invoke-AutoRemediateSCOMAgentPart1 {
[CmdletBinding(SupportsShouldProcess = $true)]
param()

$SCRIPT_VERSION = '1.0.0'
$RegPath        = 'HKLM:\Software\AirWatch\Extensions\SCOM'
$LogPath        = "$env:SystemRoot\Temp\UEM_AutoRemediateSCOMAgentPart1.log"

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
Write-Output "[$RunEventId] Executing Invoke-AutoRemediateSCOMAgent Part 1, $SCRIPT_VERSION. Started @ '$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))'  WhatIf=$WhatIfPreference"
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
    }
)

# -- Execution Engine --
# Execution order is array order. A step may still be shipped disabled by adding
# Enabled = $false to its definition; absent means enabled.
$activeSteps = @($Steps | Where-Object { -not $_.ContainsKey('Enabled') -or $_.Enabled })

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

Write-Output ''
Write-Output "`r`n-- SCOMAgentResolutionWizard Part 1 -------------------------------------"
Write-Output "   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')   Steps: $($activeSteps.Count)"
Write-Output '----------------------------------------------------------------'

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

    Write-Output "`r`n  [$($status.PadRight(7))] $($step.Name): $message$remNote"
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

Write-Output "`r`n----------------------------------------------------------------"
Write-Output "  Passed: $passed  |  Warnings: $warnings  |  Failed: $failed  |  Remediations run: $remCount"
Write-Output "`r`n----------------------------------------------------------------"
Write-Output ''

# -- Persist results for DEX sensors --
# Numerics are stored as String, not DWORD: several carry -1 for "not measured",
# and a DWORD reads that back as 4294967295. Part 3 reads these back to score.
try {
    if (-not (Test-Path $RegPath)) { New-Item -Path $RegPath -Force -ErrorAction Stop -WhatIf:$false | Out-Null }

    $values = [ordered]@{
        Part1Status            = if ($failed -gt 0) { 'Failed' } elseif ($warnings -gt 0) { 'Warning' } else { 'Passed' }
        Part1Passed            = [string]$passed
        Part1Warnings          = [string]$warnings
        Part1Failed            = [string]$failed
        Part1RemediationsRun   = [string]$remCount
        ScriptVersion          = $SCRIPT_VERSION
        ManagementServer       = $Script:MsName
        ManagementGroupCount   = [string]$Script:MgCount
        ConfigAgeHours         = [string]$Script:ConfigAgeHours
    }

    foreach ($name in $values.Keys) {
        Set-ItemProperty -Path $RegPath -Name $name -Value $values[$name] -Type String -ErrorAction Stop -WhatIf:$false
    }

    # Written LAST, deliberately: it is a commit marker, not a start marker. Every write
    # above uses -ErrorAction Stop, so a failure part-way leaves this absent and Part 3
    # correctly treats the part as not-run. Written first, a partial write would look
    # complete and Part 3 would score against metrics that were never stored.
    Set-ItemProperty -Path $RegPath -Name 'Part1RunTime' -Value (Get-Date -Format 'o') -Type String -ErrorAction Stop -WhatIf:$false

    Set-ItemProperty -Path $RegPath -Name 'AgentInstalled' -Value 1 -Type DWord -ErrorAction Stop -WhatIf:$false
    Set-ItemProperty -Path $RegPath -Name 'MsReachable'    -Value ([int]$Script:MsReachable)    -Type DWord -ErrorAction Stop -WhatIf:$false
    Set-ItemProperty -Path $RegPath -Name 'ServiceRunning' -Value ([int]$Script:ServiceHealthy) -Type DWord -ErrorAction Stop -WhatIf:$false

    Write-Log "Part 1 results cached to $RegPath"
}
catch {
    Write-Log "Failed to cache Part 1 results: $($_.Exception.Message)" -Level 'ERROR'
}

if ($failed -gt 0) { exit 1 }
exit 0
}

# -- entry point ---------------------------------------------------------------
# The param block sits inside the function deliberately. The Workspace ONE script
# engine does not recognise a param block at script scope, and $PSCmdlet is $null
# there, which makes every ShouldProcess call throw. Inputs arrive as environment
# variables and are bound to the function's parameters below.

Invoke-AutoRemediateSCOMAgentPart1
Exit 0
