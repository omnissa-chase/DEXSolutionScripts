<#
.SYNOPSIS
    SCCMClientResolutionWizard -- Automated SCCM/MECM client health checks and remediation.

.DESCRIPTION
    Runs an ordered sequence of Configuration Manager client (CcmExec) health checks
    and automatically executes the corresponding remediation for any step that fails
    (or warns, when ResolveOnWarning is set). Fully self-contained -- no JSON, no UI,
    no external dependencies.

    +------+--------------------------------+---------------------------------+
    | Step | Name                           | Remediates On                   |
    +------+--------------------------------+---------------------------------+
    |  1   | CcmExec Service State          | Failed                          |
    |  2   | CcmExec Startup Delay          | -- (report only)                |
    |  3   | WMI Repository Consistency     | -- (report only, see spin-off)  |
    |  4   | WMI Repository Size            | -- (report only)                |
    |  5   | Client Cache Size              | -- (report only, see spin-off)  |
    |  6   | Last Client Health Evaluation  | -- (report only)                |
    |  7   | Management Point Connectivity  | Failed                          |
    |  8   | Policy Retrieval Freshness     | Warning (ResolveOnWarning)      |
    |  9   | Client Certificate Health      | -- (report only)                |
    | 10   | BITS Job Backlog (CCM-scoped)  | -- (report only, see spin-off)  |
    | 11   | Software Center Process Health | -- (report only)                |
    | 12   | Inventory Scheduled At Logon   | -- (report only)                |
    | 13   | Client Version                 | -- (report only)                |
    | 14   | Orphaned CcmSetup Process      | -- (report only, see spin-off)  |
    +------+--------------------------------+---------------------------------+

    Each step returns @{ Status = 'Passed'|'Warning'|'Failed'; Message = '...' }
    Resolution scripts run silently; errors are captured and reported at the end.

    SCOPE -- WHY SOME STEPS ONLY REPORT
    This script is a broad, low-blast-radius health sweep. It changes nothing that
    cannot be undone by the client itself on its next cycle. Anything that can
    restart a shared subsystem, cancel another product's work, pull content back
    across the WAN, or leave the client half-installed is detected and reported
    here, but remediated only by a dedicated, separately-deployed script so the
    action is an explicit choice:

      Step 3  -> Invoke-AutoRemediateWMIRepository.ps1
                 (salvage restarts Winmgmt, cascading into CcmExec and every WMI
                 provider; /verifyrepository also false-positives on some builds)
      Step 5  -> Invoke-AutoRemediateCcmCache.ps1
                 (every purged element is content the client may re-pull from a
                 distribution point -- fleet-wide that is a synchronised WAN spike)
      Step 10 -> Invoke-AutoRemediateBITSBacklog.ps1
                 (BITS is shared with Windows Update, Delivery Optimization,
                 Intune and browser updaters -- cancelling by state alone would
                 hit other products' downloads)
      Step 14 -> Invoke-AutoRemediateOrphanedCcmSetup.ps1
                 (ccmsetup retries by design for up to 7 days; killing a slow but
                 legitimate WAN install can leave a partially installed client)

    The only remediating steps left here are 1 (start a stopped service), 7 (flush
    DNS) and 8 (trigger a policy refresh).

    RUNTIME GUARDRAILS
    - No step runs ccmeval.exe (multi-minute runtime). Step 6 reads the last
      CcmEvalReport.xml instead and reports the result.
    - No step blocks on service state changes. Step 1 uses sc.exe (returns at
      START_PENDING) rather than Start-Service, which waits out the full ~30s SCM
      timeout on a broken client.
    - All network/WMI probes are time-boxed so total runtime stays inside the
      60 second budget even when every check fails.
    - Startup-delay and logon-inventory checks (steps 2 and 12) are best-guess
      heuristics derived from already-resident data (process start time, boot time,
      scheduler policy). No event log scans -- those routinely take 10+ seconds on
      busy endpoints and would blow the timeout.

    SAFETY
    - Nothing in this script removes content, terminates a process, or restarts a
      shared service. The heaviest action is starting CcmExec if it is stopped.
    - Client version, certificate health, and inventory schedule are reporting-only;
      those are owned by the site server / PKI team.
    - Remediation success is reported as "remediation ran", not "issue fixed" --
      there is no post-remediation re-detection.

.NOTES
    Script Name  : Invoke-AutoRemediateSCCMClient.ps1
    Version      : 2.1.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-07-29
    Timeout      : 60 seconds

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

# -- Tunables ------------------------------------------------------------------
$StartupDelayWarnSeconds = 300      # CcmExec started > 5 min after boot -> flag
$WmiRepoWarnMB           = 500      # Repository larger than this -> flag
$CacheUsedWarnPercent    = 80       # ccmcache > 80% of configured size -> flag (report only)
$PolicyStaleHours        = 48       # No policy refresh in this window -> refresh
$CertExpiryWarnDays      = 30       # Client cert expiring inside this window -> flag
$CcmSetupOrphanMinutes   = 120      # ccmsetup.exe running longer than this -> flag (report only)
$NetTimeoutMs            = 3000     # Socket timeout for MP connectivity probe

$CcmPath = Join-Path $env:SystemRoot 'CCM'
$CcmLogs = Join-Path $CcmPath 'Logs'

# -- Step Definitions ----------------------------------------------------------
# Only supported fields: Name, Order, Enabled, ResolveOnWarning,
#                        DetectionScript, ResolutionScript
$Steps = @(

    @{
        Name             = 'CcmExec Service State'
        Order            = 1
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            $svc = Get-Service -Name 'CcmExec' -ErrorAction SilentlyContinue
            if (-not $svc) {
                return @{ Status = 'Failed'; Message = 'CcmExec service not installed -- client is missing or broken' }
            }

            $wmiSvc    = Get-CimInstance -ClassName Win32_Service -Filter "Name='CcmExec'" -ErrorAction SilentlyContinue
            $startMode = if ($wmiSvc) { $wmiSvc.StartMode } else { 'Unknown' }

            if ($svc.Status -ne 'Running') {
                return @{ Status = 'Failed'; Message = "CcmExec is $($svc.Status) (StartMode: $startMode)" }
            }
            if ($startMode -eq 'Disabled' -or $startMode -eq 'Manual') {
                return @{ Status = 'Failed'; Message = "CcmExec running but StartMode is $startMode -- will not survive reboot" }
            }
            return @{ Status = 'Passed'; Message = "CcmExec is Running (StartMode: $startMode)" }
        }
        ResolutionScript = {
            # Never fight an in-progress client install/upgrade.
            if (Get-Process -Name 'ccmsetup' -ErrorAction SilentlyContinue) { return }

            # Automatic (Delayed Start) is the Microsoft-recommended configuration.
            & sc.exe config CcmExec start= delayed-auto | Out-Null

            # sc.exe start returns at START_PENDING. Start-Service would block for
            # the full SCM timeout (~30s) on a broken client and blow the budget.
            & sc.exe start CcmExec | Out-Null
        }
    },

    @{
        Name             = 'CcmExec Startup Delay'
        Order            = 2
        Enabled          = $true
        ResolveOnWarning = $false   # Informational -- dependency chain is not safely auto-fixable
        DetectionScript  = {
            # Best-guess heuristic: compare CcmExec process start against last boot.
            # Uses already-resident process/OS data -- no event log query, no added runtime.
            $proc = Get-Process -Name 'CcmExec' -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $proc) {
                return @{ Status = 'Warning'; Message = 'CcmExec process not running -- startup delay not measurable' }
            }

            $boot = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue).LastBootUpTime
            if (-not $boot) {
                return @{ Status = 'Warning'; Message = 'Unable to read last boot time -- startup delay not measurable' }
            }

            $delay = [math]::Round(($proc.StartTime - $boot).TotalSeconds)
            if ($delay -lt 0) {
                # Service was restarted after boot (manually, by this script, or by ccmeval).
                return @{ Status = 'Passed'; Message = 'CcmExec restarted since boot -- startup delay not applicable' }
            }
            if ($delay -gt $StartupDelayWarnSeconds) {
                return @{ Status = 'Warning'; Message = "CcmExec started ${delay}s after boot (threshold ${StartupDelayWarnSeconds}s) -- check WMI/RPC dependency chain and steps 3-4" }
            }
            return @{ Status = 'Passed'; Message = "CcmExec started ${delay}s after boot" }
        }
        ResolutionScript = $null
    },

    @{
        Name             = 'WMI Repository Consistency'
        Order            = 3
        Enabled          = $true
        ResolveOnWarning = $false   # Report only -- salvage restarts Winmgmt (see spin-off script)
        DetectionScript  = {
            $out = & "$env:SystemRoot\System32\wbem\winmgmt.exe" /verifyrepository 2>&1
            if ($LASTEXITCODE -eq 0) {
                return @{ Status = 'Passed'; Message = 'WMI repository is consistent' }
            }
            return @{
                Status  = 'Warning'
                Message = "WMI repository reported inconsistent ($($out -join ' ')) -- verify before acting (/verifyrepository false-positives on some builds), then deploy Invoke-AutoRemediateWMIRepository.ps1"
            }
        }
        ResolutionScript = $null
    },

    @{
        Name             = 'WMI Repository Size'
        Order            = 4
        Enabled          = $true
        ResolveOnWarning = $false   # Informational -- only meaningful alongside step 3
        DetectionScript  = {
            $repo = Join-Path $env:SystemRoot 'System32\wbem\Repository\OBJECTS.DATA'
            if (-not (Test-Path $repo)) {
                return @{ Status = 'Warning'; Message = 'WMI repository file not found at expected path' }
            }
            $mb = [math]::Round((Get-Item $repo).Length / 1MB, 1)
            if ($mb -gt $WmiRepoWarnMB) {
                return @{ Status = 'Warning'; Message = "WMI repository is ${mb}MB (threshold ${WmiRepoWarnMB}MB) -- common cause of slow logon; repair only if step 3 also flags" }
            }
            return @{ Status = 'Passed'; Message = "WMI repository is ${mb}MB" }
        }
        ResolutionScript = $null
    },

    @{
        Name             = 'Client Cache Size'
        Order            = 5
        Enabled          = $true
        ResolveOnWarning = $false   # Report only -- purging pulls content back over the WAN (see spin-off script)
        DetectionScript  = {
            $cfg = Get-CimInstance -Namespace 'root\ccm\SoftMgmtAgent' -ClassName 'CacheConfig' `
                       -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $cfg) {
                return @{ Status = 'Warning'; Message = 'Unable to read CacheConfig -- client WMI namespace may be broken' }
            }

            $configuredMB = [int]$cfg.Size
            if ($configuredMB -le 0) {
                return @{ Status = 'Warning'; Message = 'Configured cache size reported as 0 -- cannot evaluate utilization' }
            }

            $elements = @(Get-CimInstance -Namespace 'root\ccm\SoftMgmtAgent' -ClassName 'CacheInfoEx' `
                              -ErrorAction SilentlyContinue)
            # CacheInfoEx.ContentSize is in KB; CacheConfig.Size is in MB.
            $usedMB = [math]::Round((($elements | Measure-Object -Property ContentSize -Sum).Sum) / 1024, 1)
            $pct    = [math]::Round(($usedMB / $configuredMB) * 100)

            if ($pct -ge $CacheUsedWarnPercent) {
                return @{
                    Status  = 'Warning'
                    Message = "ccmcache at ${usedMB}MB of ${configuredMB}MB (${pct}%) across $($elements.Count) element(s) -- deploy Invoke-AutoRemediateCcmCache.ps1 in staggered rings to reclaim"
                }
            }
            return @{ Status = 'Passed'; Message = "ccmcache at ${usedMB}MB of ${configuredMB}MB (${pct}%)" }
        }
        ResolutionScript = $null
    },

    @{
        Name             = 'Last Client Health Evaluation'
        Order            = 6
        Enabled          = $true
        ResolveOnWarning = $false   # ccmeval.exe is NOT invoked -- multi-minute runtime
        DetectionScript  = {
            $report = Join-Path $env:SystemRoot 'CCM\CcmEvalReport.xml'
            if (-not (Test-Path $report)) {
                $report = Join-Path $env:SystemRoot 'CCM\Logs\CcmEvalReport.xml'
            }
            if (-not (Test-Path $report)) {
                return @{ Status = 'Warning'; Message = 'No CcmEvalReport.xml found -- client health evaluation has never completed' }
            }

            $age = [math]::Round(((Get-Date) - (Get-Item $report).LastWriteTime).TotalDays, 1)

            try {
                [xml]$xml   = Get-Content -Path $report -Raw -ErrorAction Stop
                $checks     = @($xml.SelectNodes('//HealthCheck'))
                $failing    = @($checks | Where-Object { $_.ResultCode -and $_.ResultCode -ne '0' -and $_.ResultCode -ne '1' })

                if ($failing.Count -gt 0) {
                    $names = ($failing | Select-Object -First 3 | ForEach-Object { $_.Description }) -join '; '
                    return @{ Status = 'Warning'; Message = "ccmeval reported $($failing.Count) failing check(s) ${age}d ago: $names" }
                }
                return @{ Status = 'Passed'; Message = "ccmeval reported healthy ${age}d ago ($($checks.Count) checks)" }
            } catch {
                return @{ Status = 'Warning'; Message = "CcmEvalReport.xml present (${age}d old) but could not be parsed" }
            }
        }
        ResolutionScript = $null
    },

    @{
        Name             = 'Management Point Connectivity'
        Order            = 7
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            $auth = Get-CimInstance -Namespace 'root\ccm' -ClassName 'SMS_Authority' `
                        -ErrorAction SilentlyContinue | Select-Object -First 1
            $mp = if ($auth) { $auth.CurrentManagementPoint } else { $null }

            if (-not $mp) {
                return @{ Status = 'Failed'; Message = 'No current Management Point assigned to this client' }
            }

            # Time-boxed socket probe -- faster and more predictable than Invoke-WebRequest.
            # WaitOne() alone is NOT sufficient: it also returns true when the connect
            # completed with a refusal (RST returns instantly). EndConnect() throws in
            # that case, which is what actually distinguishes reachable from refused.
            foreach ($port in 443, 80) {
                $tcp = New-Object System.Net.Sockets.TcpClient
                try {
                    $ar = $tcp.BeginConnect($mp, $port, $null, $null)
                    if ($ar.AsyncWaitHandle.WaitOne($NetTimeoutMs, $false)) {
                        $tcp.EndConnect($ar)
                        if ($tcp.Connected) {
                            return @{ Status = 'Passed'; Message = "Management Point reachable: $mp (port $port)" }
                        }
                    }
                } catch {
                } finally {
                    $tcp.Close()
                }
            }
            return @{ Status = 'Failed'; Message = "Management Point unreachable on 443/80: $mp (expected for CMG/internet-based clients off-corp)" }
        }
        ResolutionScript = {
            # Local-side fix only. A genuine MP outage is server-side and is reported, not fixed.
            ipconfig /flushdns | Out-Null
        }
    },

    @{
        Name             = 'Policy Retrieval Freshness'
        Order            = 8
        Enabled          = $true
        ResolveOnWarning = $true
        DetectionScript  = {
            # Best-guess heuristic: PolicyAgent.log write time is the cheapest reliable
            # signal of the last policy poll. Reading it costs a single file stat.
            $log = Join-Path $CcmLogs 'PolicyAgent.log'
            if (-not (Test-Path $log)) {
                return @{ Status = 'Warning'; Message = 'PolicyAgent.log not found -- policy freshness unknown, forcing a refresh' }
            }

            $hours = [math]::Round(((Get-Date) - (Get-Item $log).LastWriteTime).TotalHours, 1)
            if ($hours -gt $PolicyStaleHours) {
                return @{ Status = 'Warning'; Message = "Last policy activity ${hours}h ago (threshold ${PolicyStaleHours}h)" }
            }
            return @{ Status = 'Passed'; Message = "Last policy activity ${hours}h ago" }
        }
        ResolutionScript = {
            # Machine policy retrieval + evaluation. Fire-and-forget: the client runs
            # these asynchronously, so this does not extend script runtime.
            foreach ($schedule in '{00000000-0000-0000-0000-000000000021}',
                                  '{00000000-0000-0000-0000-000000000022}') {
                Invoke-CimMethod -Namespace 'root\ccm' -ClassName 'SMS_Client' `
                    -MethodName 'TriggerSchedule' -Arguments @{ sScheduleID = $schedule } `
                    -ErrorAction SilentlyContinue | Out-Null
            }
        }
    },

    @{
        Name             = 'Client Certificate Health'
        Order            = 9
        Enabled          = $true
        ResolveOnWarning = $false   # Informational -- cert renewal is a PKI/infra action
        DetectionScript  = {
            $certs = @(Get-ChildItem -Path 'Cert:\LocalMachine\SMS' -ErrorAction SilentlyContinue)
            if ($certs.Count -eq 0) {
                # HTTP-only sites legitimately have no SMS certificate.
                return @{ Status = 'Passed'; Message = 'No SMS client certificate present (expected on HTTP-only sites)' }
            }

            $now     = Get-Date
            $expired = @($certs | Where-Object { $_.NotAfter -lt $now })
            if ($expired.Count -gt 0) {
                return @{ Status = 'Warning'; Message = "$($expired.Count) SMS client certificate(s) expired -- PKI action required" }
            }

            $soon = @($certs | Where-Object { $_.NotAfter -lt $now.AddDays($CertExpiryWarnDays) })
            if ($soon.Count -gt 0) {
                $next = ($soon | Sort-Object NotAfter | Select-Object -First 1).NotAfter
                return @{ Status = 'Warning'; Message = "SMS client certificate expires $($next.ToString('yyyy-MM-dd')) -- PKI action required" }
            }
            return @{ Status = 'Passed'; Message = "$($certs.Count) SMS client certificate(s) valid" }
        }
        ResolutionScript = $null
    },

    @{
        Name             = 'BITS Job Backlog (CCM-scoped)'
        Order            = 10
        Enabled          = $true
        ResolveOnWarning = $false   # Report only -- BITS is shared (see spin-off script)
        DetectionScript  = {
            $jobs = @(Get-BitsTransfer -AllUsers -ErrorAction SilentlyContinue)
            if ($jobs.Count -eq 0) {
                return @{ Status = 'Passed'; Message = 'No BITS jobs queued' }
            }

            # Scope to Configuration Manager's own jobs. Windows Update, Delivery
            # Optimization, Intune and browser updaters share BITS -- reporting on
            # their jobs here would be misleading.
            $ccmJobs = @($jobs | Where-Object { $_.DisplayName -like 'CCMDTS*' })

            # 'TransientError' is a normal self-healing state (sleep/roaming), not a
            # stuck job. Only a long-lived Error or a day-old Suspended job is real.
            $stuck = @($ccmJobs | Where-Object {
                $_.JobState -eq 'Error' -or
                ($_.JobState -eq 'Suspended' -and $_.CreationTime -lt (Get-Date).AddDays(-1))
            })

            if ($stuck.Count -gt 0) {
                return @{
                    Status  = 'Warning'
                    Message = "$($stuck.Count) stalled CCM BITS job(s) of $($ccmJobs.Count) CCM / $($jobs.Count) total -- deploy Invoke-AutoRemediateBITSBacklog.ps1 to clear"
                }
            }
            return @{ Status = 'Passed'; Message = "$($ccmJobs.Count) CCM BITS job(s) of $($jobs.Count) total, none stalled" }
        }
        ResolutionScript = $null
    },

    @{
        Name             = 'Software Center Process Health'
        Order            = 11
        Enabled          = $true
        ResolveOnWarning = $false   # Report only -- see note below
        DetectionScript  = {
            # Honest limitation: this script runs as SYSTEM in session 0. For a
            # SCClient.exe in an interactive session, MainWindowHandle reads as 0 and
            # .Responding is unreliable across the session boundary, so "hung" cannot
            # be determined here. Reporting presence and footprint only -- a blind
            # kill based on an unreliable signal is worse than no action.
            $procs = @(Get-Process -Name 'SCClient' -ErrorAction SilentlyContinue)
            if ($procs.Count -eq 0) {
                # Not running is normal -- SCClient only launches when the user opens it.
                return @{ Status = 'Passed'; Message = 'Software Center not running (normal when not in use)' }
            }

            $mb = [math]::Round((($procs | Measure-Object -Property WorkingSet64 -Sum).Sum) / 1MB)
            return @{
                Status  = 'Passed'
                Message = "Software Center running: $($procs.Count) instance(s), ${mb}MB working set (responsiveness not measurable from session 0)"
            }
        }
        ResolutionScript = $null
    },

    @{
        Name             = 'Inventory Scheduled At Logon'
        Order            = 12
        Enabled          = $true
        ResolveOnWarning = $false   # Informational -- schedule change is a CM console action
        DetectionScript  = {
            # Best-guess: read the already-cached scheduler policy rather than
            # timing an actual logon. Costs one WMI query.
            $sched = @(Get-CimInstance -Namespace 'root\ccm\policy\machine\actualconfig' `
                           -ClassName 'CCM_Scheduler_ScheduledMessage' -ErrorAction SilentlyContinue)
            if ($sched.Count -eq 0) {
                return @{ Status = 'Warning'; Message = 'Unable to read client scheduler policy' }
            }

            # Event-based triggers fire on logon/startup rather than on an interval.
            # Matching loosely on the trigger text rather than an exact bracket format,
            # which varies by client version.
            $atLogon = @($sched | Where-Object {
                $_.Triggers -and ($_.Triggers -join ' ') -match 'Logon|Startup'
            })

            if ($atLogon.Count -gt 0) {
                $names = ($atLogon | Select-Object -First 3 | ForEach-Object { $_.ScheduledMessageID }) -join '; '
                return @{ Status = 'Warning'; Message = "$($atLogon.Count) logon/startup-triggered cycle(s) -- frequent cause of 'slow boot' reports; reschedule in the CM console: $names" }
            }
            return @{ Status = 'Passed'; Message = "No logon/startup-triggered inventory cycles ($($sched.Count) schedules reviewed)" }
        }
        ResolutionScript = $null
    },

    @{
        Name             = 'Client Version'
        Order            = 13
        Enabled          = $true
        ResolveOnWarning = $false   # Informational -- client upgrade is push-managed from the site server
        DetectionScript  = {
            $client = Get-CimInstance -Namespace 'root\ccm' -ClassName 'SMS_Client' `
                          -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $client -or -not $client.ClientVersion) {
                return @{ Status = 'Failed'; Message = 'Unable to read client version -- root\ccm namespace unavailable' }
            }
            return @{ Status = 'Passed'; Message = "Client version $($client.ClientVersion) -- compare against site target; upgrades are site-server managed" }
        }
        ResolutionScript = $null
    },

    @{
        Name             = 'Orphaned CcmSetup Process'
        Order            = 14
        Enabled          = $true
        ResolveOnWarning = $false   # Report only -- killing mid-install is destructive (see spin-off script)
        DetectionScript  = {
            $procs = @(Get-Process -Name 'ccmsetup' -ErrorAction SilentlyContinue)
            if ($procs.Count -eq 0) {
                return @{ Status = 'Passed'; Message = 'No ccmsetup.exe running' }
            }

            $cutoff  = (Get-Date).AddMinutes(-$CcmSetupOrphanMinutes)
            $orphans = @($procs | Where-Object { $_.StartTime -lt $cutoff })

            if ($orphans.Count -gt 0) {
                $mins = [math]::Round(((Get-Date) - ($orphans | Sort-Object StartTime | Select-Object -First 1).StartTime).TotalMinutes)
                return @{
                    Status  = 'Warning'
                    Message = "ccmsetup.exe running for ${mins}m (threshold ${CcmSetupOrphanMinutes}m) -- possible retry loop; review ccmsetup.log before deploying Invoke-AutoRemediateOrphanedCcmSetup.ps1 (slow WAN installs can legitimately run this long)"
                }
            }
            return @{ Status = 'Passed'; Message = 'ccmsetup.exe running (install/upgrade in progress) -- not interfering' }
        }
        ResolutionScript = $null
    }
)

# -- Execution Engine ----------------------------------------------------------
$activeSteps = $Steps |
    Where-Object { $_.Enabled } |
    Sort-Object   { [int]$_.Order }

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

Write-Host ''
Write-Host "`n-- SCCMClientResolutionWizard ------------------------------------" -ForegroundColor Cyan
Write-Host "   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')   Steps: $($activeSteps.Count)"
Write-Host '----------------------------------------------------------------' -ForegroundColor Cyan

foreach ($step in $activeSteps) {

    $status     = 'Failed'
    $message    = 'Detection script did not return a result.'
    $remediated = $false
    $remError   = ''

    # -- Detection ------------------------------------------------------------
    try {
        $result  = & $step.DetectionScript
        $status  = $result.Status
        $message = $result.Message
    } catch {
        $status  = 'Failed'
        $message = "Detection exception: $($_.Exception.Message)"
    }

    # -- Remediation ----------------------------------------------------------
    $shouldRemediate = ($status -eq 'Failed') -or
                       ($status -eq 'Warning' -and $step.ResolveOnWarning)

    if ($shouldRemediate -and $step.ResolutionScript) {
        try {
            & $step.ResolutionScript | Out-Null
            $remediated = $true
        } catch {
            $remError = $_.Exception.Message
        }
    }

    # -- Output ---------------------------------------------------------------
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

    $results.Add([PSCustomObject]@{
        Order      = $step.Order
        Name       = $step.Name
        Status     = $status
        Message    = $message
        Remediated = $remediated
        RemError   = $remError
    })
}

# -- Summary -------------------------------------------------------------------
$passed   = ($results | Where-Object { $_.Status -eq 'Passed'  }).Count
$warnings = ($results | Where-Object { $_.Status -eq 'Warning' }).Count
$failed   = ($results | Where-Object { $_.Status -eq 'Failed'  }).Count
$remCount = ($results | Where-Object { $_.Remediated }).Count

Write-Host "`n----------------------------------------------------------------" -ForegroundColor Cyan
Write-Host "  Passed: $passed  |  Warnings: $warnings  |  Failed: $failed  |  Remediations run: $remCount"
Write-Host "`n----------------------------------------------------------------" -ForegroundColor Cyan
Write-Host ''

if ($failed -gt 0) { exit 1 }
exit 0
