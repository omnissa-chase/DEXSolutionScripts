#Requires -Version 5.1
<#
.SYNOPSIS
    SCOMAgentResolutionWizard Part 3 of 3 -- certificate, version, time, sub-services, and scoring.

.DESCRIPTION
    Steps 11-14 of the Operations Manager agent health sweep, plus the health score for
    the whole sweep. Split into three UEM script objects because the combined sweep is
    48,336 characters against a 32,767 limit.

      11 Channel Certificate Health    report (PKI-owned)
      12 Agent Version                 report
      13 Time Synchronisation Skew     report, cross-references TimeSyncHealth
      14 Optional Agent Sub-services   report

    THIS PART MUST RUN LAST.
    It measures only steps 11-14 itself. Every other metric is read back from
    HKLM:\Software\AirWatch\Extensions\SCOM, where Parts 1 and 2 cached it, and the full
    deduction table is then applied to the union. Schedule it after the other two.

    If Part 1 or Part 2 has not run inside $StalePartHours, their metrics are missing.
    Missing reads return a negative sentinel, and every threshold below compares against
    a positive number, so an absent metric simply fails its test rather than deducting --
    the score comes out too HIGH, never too low. ScoreComplete is written 0 in that case
    and the health-score sensor should filter on it. It is not a soft warning: a score
    with ScoreComplete = 0 is measuring a fraction of the agent and saying nothing about
    the rest.

    >> Deployment, the reason table, sensor contract and tunables are in
       ApplicationSpecific/SCOM/README.md. Read it before deploying.

.NOTES
    Script Name  : Invoke-AutoRemediateSCOMAgentPart3.ps1
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

[CmdletBinding(SupportsShouldProcess = $true)]
param()

$SCRIPT_VERSION = '1.0.0'
$RegPath        = 'HKLM:\Software\AirWatch\Extensions\SCOM'
$LogPath        = "$env:SystemRoot\Temp\UEM_AutoRemediateSCOMAgentPart3.log"

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
$StalePartHours            = 26      # Parts 1/2 older than this make the score incomplete    # Ceiling on events pulled in the single log pass

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
Write-Host "[$RunEventId] Executing Invoke-AutoRemediateSCOMAgent Part 3, $SCRIPT_VERSION. Started @ '$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))'  WhatIf=$WhatIfPreference"
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
Write-Host "`n-- SCOMAgentResolutionWizard Part 3 -------------------------------------" -ForegroundColor Cyan
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

# -- Cross-part metric read --
# Steps 11-14 measured locally; everything else comes from what Parts 1 and 2 cached.
# A missing or unparseable value returns -1. Every test below matches on a positive
# threshold or an explicit -eq 0, so -1 never deducts -- an absent metric cannot
# fabricate a fault.
function Get-Cached {
    param([string]$Name, [int]$Default = -1)
    try {
        $v = (Get-ItemProperty -Path $RegPath -Name $Name -ErrorAction SilentlyContinue).$Name
        if ($null -eq $v) { return $Default }
        $n = 0
        if ([int]::TryParse([string]$v, [ref]$n)) { return $n }
    }
    catch { }
    return $Default
}

$mServiceRunning = Get-Cached 'ServiceRunning'       -1
$mMsReachable    = Get-Cached 'MsReachable'          -1
$mMgCount        = Get-Cached 'ManagementGroupCount' -1
$mConfigAge      = Get-Cached 'ConfigAgeHours'
$mStateFolderMB  = Get-Cached 'StateFolderMB'
$mStoreDbErrors  = Get-Cached 'StoreDbErrors24h'
$mRuntimeMemMB   = Get-Cached 'RuntimeMemoryMB'
$mRuntimeCpu     = Get-Cached 'RuntimeCpuPercent'
$mConnectFails   = Get-Cached 'ConnectFailures24h'
$mAuthFails      = Get-Cached 'AuthFailures24h'
$mNotRegistered  = Get-Cached 'NotRegistered24h'
$mUnloaded       = Get-Cached 'UnloadedWorkflows24h'
$mMsName         = [string](Get-ItemProperty -Path $RegPath -Name 'ManagementServer' -ErrorAction SilentlyContinue).ManagementServer

# Completeness: did Parts 1 and 2 both run recently AND actually store their metrics?
# Two checks, because either alone can lie. The timestamp alone would trust a part whose
# metric writes failed after the marker; a witness metric alone would trust yesterday's
# data. Each part writes its marker LAST, so marker-present normally implies metrics
# stored -- the witness is the belt to that braces, covering a partially deleted key.
$partsFresh = $true
$witness = @{ Part1RunTime = 'ServiceRunning'; Part2RunTime = 'StateFolderMB' }
foreach ($p in $witness.Keys) {
    $raw = (Get-ItemProperty -Path $RegPath -Name $p -ErrorAction SilentlyContinue).$p
    $parsed = [datetime]::MinValue
    if (-not $raw -or -not [datetime]::TryParse([string]$raw, [ref]$parsed) -or
        $parsed -lt (Get-Date).AddHours(-$StalePartHours)) {
        $partsFresh = $false
        Write-Log "$p missing or older than ${StalePartHours}h -- health score will be incomplete." -Level 'WARN'
        continue
    }
    $w = $witness[$p]
    if ($null -eq (Get-ItemProperty -Path $RegPath -Name $w -ErrorAction SilentlyContinue).$w) {
        $partsFresh = $false
        Write-Log "$p is current but its metric '$w' is absent -- treating that part as not run." -Level 'WARN'
    }
}

# -- Health score --
# Deduction table, identical to OneTimeSensor/scom_agent_health.ps1. Every rule is
# evaluated; the largest single deduction becomes the reported HealthReason.
$healthScore = 100
$deductions  = @()

$DeductionRules = @(
    @{ Points = 40; Reason = 'HealthServiceStopped'; Test = { $mServiceRunning -eq 0 } }
    @{ Points = 25; Reason = 'ManagementServerUnreachable'; Test = { $mMsName -and $mMsReachable -eq 0 } }
    @{ Points = 25; Reason = 'AgentNotRegistered'; Test = { $mNotRegistered -gt 0 } }
    @{ Points = 20; Reason = 'NoManagementGroup'; Test = { $mMgCount -eq 0 } }
    @{ Points = 20; Reason = 'ConnectorAuthenticationFailure'; Test = { $mAuthFails -gt 0 } }
    @{ Points = 20; Reason = 'HealthServiceStoreCorruption'; Test = { $mStoreDbErrors -gt 0 } }
    @{ Points = 15; Reason = 'ConfigurationCacheStale'; Test = { $mConfigAge -ge 0 -and $mConfigAge -gt $ConfigStaleHours } }
    @{ Points = 15; Reason = 'AgentRuntimeFootprintHigh'; Test = { $mRuntimeMemMB -gt $RuntimeMemoryWarnMB -or ($mRuntimeCpu -ge 0 -and $mRuntimeCpu -gt $RuntimeCpuWarnPercent) } }
    @{ Points = 15; Reason = 'ChannelCertificateProblem'; Test = { $Script:CertProblem } }
    @{ Points = 15; Reason = 'TimeSkew'; Test = { $Script:TimeSkewSeconds -ge 0 -and $Script:TimeSkewSeconds -gt $TimeSkewWarnSeconds } }
    @{ Points = 10; Reason = 'WorkflowsUnloaded'; Test = { $mUnloaded -ge $UnloadedWorkflowWarnCount } }
    @{ Points = 10; Reason = 'HealthServiceStateOversized'; Test = { $mStateFolderMB -gt $StateFolderWarnMB } }
    @{ Points =  5; Reason = 'MultiHomedAgent'; Test = { $mMgCount -gt 1 } }
    @{ Points =  5; Reason = 'IntermittentConnectivity'; Test = { $mConnectFails -ge $ConnectFailureWarnCount } }
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

Write-Output "$HEAD Health score: $healthScore ($healthReason)$(if (-not $partsFresh) { ' -- INCOMPLETE, Part 1 or 2 has not run recently' })"
Write-Log "Health score: $healthScore | Reason: $healthReason | Complete: $partsFresh"
# -- Persist results for DEX sensors --
# This part writes both its own metrics and the sweep-wide aggregate, because it is the
# one that runs last and can see all three parts' results.
try {
    if (-not (Test-Path $RegPath)) { New-Item -Path $RegPath -Force -ErrorAction Stop -WhatIf:$false | Out-Null }

    $p1f = Get-Cached 'Part1Failed'   0
    $p2f = Get-Cached 'Part2Failed'   0
    $p1w = Get-Cached 'Part1Warnings' 0
    $p2w = Get-Cached 'Part2Warnings' 0
    $p1p = Get-Cached 'Part1Passed'   0
    $p2p = Get-Cached 'Part2Passed'   0
    $p1r = Get-Cached 'Part1RemediationsRun' 0
    $p2r = Get-Cached 'Part2RemediationsRun' 0

    $allFailed   = $p1f + $p2f + $failed
    $allWarnings = $p1w + $p2w + $warnings
    $allPassed   = $p1p + $p2p + $passed

    $values = [ordered]@{
        Part3Status            = if ($failed -gt 0) { 'Failed' } elseif ($warnings -gt 0) { 'Warning' } else { 'Passed' }
        Part3Passed            = [string]$passed
        Part3Warnings          = [string]$warnings
        Part3Failed            = [string]$failed
        Part3RemediationsRun   = [string]$remCount
        CertExpiryDays         = [string]$Script:CertExpiryDays
        AgentVersion           = $Script:AgentVersion
        TimeSkewSeconds        = [string]$Script:TimeSkewSeconds
        Status                 = if ($allFailed -gt 0) { 'Failed' } elseif ($allWarnings -gt 0) { 'Warning' } else { 'Passed' }
        LastRunTime            = (Get-Date -Format 'o')
        # An incomplete sweep publishes the SENTINEL, not the partial score. Missing
        # metrics cannot deduct, so a partial score is always too high -- caching it
        # would tell every sensor the agent is healthier than anyone actually measured.
        # -1 / IncompleteSweep matches the NoAgentInstalled convention: not a low score,
        # a statement that no score was obtained. Sensors stay pure cache readers.
        HealthScore            = if ($partsFresh) { [string]$healthScore } else { '-1' }
        HealthReason           = if ($partsFresh) { $healthReason } else { 'IncompleteSweep' }
        Passed                 = [string]$allPassed
        Warnings               = [string]$allWarnings
        Failed                 = [string]$allFailed
        RemediationsRun        = [string]($p1r + $p2r + $remCount)
    }

    foreach ($name in $values.Keys) {
        Set-ItemProperty -Path $RegPath -Name $name -Value $values[$name] -Type String -ErrorAction Stop -WhatIf:$false
    }

    # Written LAST, deliberately: it is a commit marker, not a start marker. Every write
    # above uses -ErrorAction Stop, so a failure part-way leaves this absent and Part 3
    # correctly treats the part as not-run. Written first, a partial write would look
    # complete and Part 3 would score against metrics that were never stored.
    Set-ItemProperty -Path $RegPath -Name 'Part3RunTime' -Value (Get-Date -Format 'o') -Type String -ErrorAction Stop -WhatIf:$false

    Set-ItemProperty -Path $RegPath -Name 'AgentInstalled' -Value 1 -Type DWord -ErrorAction Stop -WhatIf:$false
    Set-ItemProperty -Path $RegPath -Name 'ScoreComplete'  -Value ([int]$partsFresh) -Type DWord -ErrorAction Stop -WhatIf:$false

    Write-Log "Part 3 results and sweep aggregate cached to $RegPath"
}
catch {
    Write-Log "Failed to cache Part 3 results: $($_.Exception.Message)" -Level 'ERROR'
}

if ($failed -gt 0) { exit 1 }
exit 0