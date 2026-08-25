#Requires -Version 5.1
<#
.SYNOPSIS
    SCOMAgentResolutionWizard Part 2 of 3 -- state, footprint and event-log checks.

.DESCRIPTION
    Steps 6-10 of the Operations Manager agent health sweep. Split into three UEM script
    objects because the combined sweep is 48,336 characters against a 32,767 limit.

      6  Health Service State Folder Size   report -> HealthServiceCache spin-off
      7  Health Service Store Database      report -> HealthServiceCache spin-off
      8  Agent Runtime Footprint            report -> MonitoringHost spin-off
      9  Connector Connectivity Failures    report, classifies server-side vs local
      10 Workflow Health                    report

    This part owns the single pass over the 'Operations Manager' event log -- steps 9 and
    10 share one bucketed query rather than issuing their own, and step 7 makes a second
    guarded query against the ESENT provider in the Application log. It is the most
    expensive of the three parts; budget its UEM timeout accordingly.

    Remediates nothing. Writes its metrics to HKLM:\Software\AirWatch\Extensions\SCOM
    plus a Part2RunTime marker. Part 3 reads these back to compute the health score.

    >> Deployment, the reason table, sensor contract and tunables are in
       ApplicationSpecific/SCOM/README.md. Read it before deploying.

.NOTES
    Script Name  : Invoke-AutoRemediateSCOMAgentPart2.ps1
    Version      : 1.1.0
    Architecture : x64
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-25
    Timeout      : 25 seconds (deploy with a 90 second UEM timeout)

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
$LogPath        = "$env:SystemRoot\Temp\UEM_AutoRemediateSCOMAgentPart2.log"

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
Write-Host "[$RunEventId] Executing Invoke-AutoRemediateSCOMAgent Part 2, $SCRIPT_VERSION. Started @ '$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))'  WhatIf=$WhatIfPreference"
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
    }
)

# -- Execution Engine --
# Execution order is array order. A step may still be shipped disabled by adding
# Enabled = $false to its definition; absent means enabled.
$activeSteps = @($Steps | Where-Object { -not $_.ContainsKey('Enabled') -or $_.Enabled })

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

Write-Host ''
Write-Host "`n-- SCOMAgentResolutionWizard Part 2 -------------------------------------" -ForegroundColor Cyan
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

# -- Persist results for DEX sensors --
# Numerics are stored as String, not DWORD: several carry -1 for "not measured",
# and a DWORD reads that back as 4294967295. Part 3 reads these back to score.
try {
    if (-not (Test-Path $RegPath)) { New-Item -Path $RegPath -Force -ErrorAction Stop -WhatIf:$false | Out-Null }

    $values = [ordered]@{
        Part2Status            = if ($failed -gt 0) { 'Failed' } elseif ($warnings -gt 0) { 'Warning' } else { 'Passed' }
        Part2Passed            = [string]$passed
        Part2Warnings          = [string]$warnings
        Part2Failed            = [string]$failed
        Part2RemediationsRun   = [string]$remCount
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
    }

    foreach ($name in $values.Keys) {
        Set-ItemProperty -Path $RegPath -Name $name -Value $values[$name] -Type String -ErrorAction Stop -WhatIf:$false
    }

    # Written LAST, deliberately: it is a commit marker, not a start marker. Every write
    # above uses -ErrorAction Stop, so a failure part-way leaves this absent and Part 3
    # correctly treats the part as not-run. Written first, a partial write would look
    # complete and Part 3 would score against metrics that were never stored.
    Set-ItemProperty -Path $RegPath -Name 'Part2RunTime' -Value (Get-Date -Format 'o') -Type String -ErrorAction Stop -WhatIf:$false

    Set-ItemProperty -Path $RegPath -Name 'AgentInstalled' -Value 1 -Type DWord -ErrorAction Stop -WhatIf:$false

    Write-Log "Part 2 results cached to $RegPath"
}
catch {
    Write-Log "Failed to cache Part 2 results: $($_.Exception.Message)" -Level 'ERROR'
}

if ($failed -gt 0) { exit 1 }
exit 0