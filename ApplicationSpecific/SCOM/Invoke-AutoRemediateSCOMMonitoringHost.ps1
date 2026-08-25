#Requires -Version 5.1
<#
.SYNOPSIS
    SCOMMonitoringHostResolutionWizard -- Recycle a runaway Operations Manager agent.

.DESCRIPTION
    Split out of Invoke-AutoRemediateSCOMAgent.ps1 deliberately. Deploying THIS script
    is the opt-in -- do not fold it back into a general health sweep.

    +------+----------------------------------+----------------------------------+
    | Step | Name                             | Remediates On                    |
    +------+----------------------------------+----------------------------------+
    |  1   | Agent Present Guard              | -- (abort gate)                  |
    |  2   | Configuration Activity Guard     | -- (abort gate)                  |
    |  3   | Sustained Load Confirmation      | -- (abort gate)                  |
    |  4   | Agent Recycle                    | Failed                           |
    |  5   | Post-Recycle Verification        | -- (report only)                 |
    +------+----------------------------------+----------------------------------+

    THE PROBLEM THIS SOLVES
    On a server nobody notices MonitoringHost.exe consuming a core. On a laptop or a
    shared VDI host the user notices immediately, and they do not report it as
    "monitoring is broken" -- they report it as "my machine is slow". A management
    pack script that errors in a tight loop, a discovery running against a target
    that no longer exists, or a leaking workflow will pin MonitoringHost indefinitely
    because the agent has no self-recycling behaviour for the general case.

    WHY THIS IS NOT AUTO-RUN FLEET-WIDE
    - A recycle discards every workflow's in-memory state and anything queued but
      not yet uploaded. The console shows a monitoring gap for the window.
    - A single CPU reading proves nothing. Discovery and management pack load are
      bursty by design; a script that recycles on one sample will recycle healthy
      agents all day and hide the real problem.
    - The recycle treats the symptom. The cause is a specific workflow in a specific
      management pack, and it will come back on the next cycle. Step 5 reports what
      it can so that the management pack owner has something to act on -- this script
      is a stopgap for the user's experience, not a fix.

    WHY THERE IS NO ConfirmHighImpact GATE HERE
    Unlike the state-cache flush, this restarts the agent's own service and deletes
    nothing. It is recoverable on its own next cycle, no other product depends on
    HealthService, and no user session or unsaved data is at risk. The protection
    that matters for this action is evidence, not confirmation -- so the gates are
    two independent load samples plus a once-per-day cap, and they are strict.

.NOTES
    Script Name  : Invoke-AutoRemediateSCOMMonitoringHost.ps1
    Version      : 1.0.0
    Architecture : x64
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-21
    Timeout      : ~5 seconds (launcher exits immediately; payload runs via scheduled task, self-capped at 10 minutes)

    Environment variables:
      WhatIf = true    Dry run. Absent/unparseable => live run.

    ADMIN PREREQUISITE
      Add an AV/EDR exclusion for C:\ProgramData\AirWatch\Extensions\ and subfolders.
      Without it the staged payload may be quarantined and the scheduled task will
      appear to succeed while doing nothing.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param([switch]$RunAsPayload)

$SCRIPT_VERSION = '1.0.0'

# -- Dispatch constants (shared by launcher and payload) --
$TaskName   = 'WS1_SCOMMonitoringHost'
$MutexName  = 'Global\WS1_DEX_SCOMMonitoringHost'
$BaseDir    = Join-Path $env:ProgramData 'AirWatch\Extensions\SCOM'
$PayloadPs1 = Join-Path $BaseDir 'Invoke-AutoRemediateSCOMMonitoringHost.ps1'
$RegPath    = 'HKLM:\Software\AirWatch\Extensions\SCOM\MonitoringHost'
$LogPath    = "$env:SystemRoot\Temp\UEM_AutoRemediateSCOMMonitoringHost.log"

$RunEventId = ([Random]::new()).Next(1000, 9999)
$HEAD       = "`r`n[$RunEventId]"

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    "[$timestamp] [$RunEventId] [$Level] $Message" |
        Out-File -FilePath $LogPath -Append -Encoding UTF8 -WhatIf:$false -ErrorAction SilentlyContinue
}

# -- Launcher (UEM dispatcher) --
# The two load samples alone exceed the synchronous script budget, so the delivered
# script is a launcher: it stages the payload, dispatches a one-shot scheduled task,
# and exits in ~5 seconds. Results land in the registry for DEX sensors to read.
if (-not $RunAsPayload) {
    try {
        $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($existing -and $existing.State -eq 'Running') {
            Write-Output "$HEAD Payload already running. Skipping dispatch."
            exit 0
        }

        if (-not (Test-Path $BaseDir)) {
            New-Item -ItemType Directory -Path $BaseDir -Force -ErrorAction Stop -WhatIf:$false | Out-Null
        }

        Copy-Item -Path $PSCommandPath -Destination $PayloadPs1 -Force -ErrorAction Stop -WhatIf:$false

        if (-not (Test-Path $RegPath)) { New-Item -Path $RegPath -Force -ErrorAction Stop -WhatIf:$false | Out-Null }
        Set-ItemProperty -Path $RegPath -Name 'Status'           -Value 'Dispatched'          -Type String -ErrorAction Stop -WhatIf:$false
        Set-ItemProperty -Path $RegPath -Name 'LastDispatchTime' -Value (Get-Date -Format 'o') -Type String -ErrorAction Stop -WhatIf:$false

        if ($existing) {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        }

        $action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
                         -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$PayloadPs1`" -RunAsPayload"
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings  = New-ScheduledTaskSettingsSet `
                         -ExecutionTimeLimit '00:15:00' `
                         -DeleteExpiredTaskAfter '00:01:00' `
                         -StartWhenAvailable `
                         -AllowStartIfOnBatteries

        Register-ScheduledTask -TaskName $TaskName -Action $action -Principal $principal `
            -Settings $settings -Force -ErrorAction Stop -WhatIf:$false | Out-Null
        Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop

        Write-Output "$HEAD Dispatched '$TaskName'. Results will appear at: $RegPath"
        Write-Log "Dispatched task '$TaskName'."
        exit 0
    }
    catch {
        Write-Error "$HEAD Launcher failed: $($_.Exception.Message)"
        Write-Log "Launcher failed: $($_.Exception.Message)" -Level 'ERROR'
        exit 1
    }
}

# =============================================================================
#  Payload runs below this line, in the scheduled task context.
# =============================================================================

# -- Tunables --
# Hard-coded deliberately: UEM variables are per-script-object, not per-assignment.
# Fork the script object if a ring needs different values.
$CpuWarnPercent       = 20     # Interval CPU across agent processes, as a share of one machine
$MemoryWarnMB         = 500    # Combined working set of HealthService + MonitoringHost
$SampleIntervalSecs   = 45     # Gap between the two load samples
$MinIntervalHours     = 20     # Cooldown -- effectively once per day per device
$RecentStartMinutes   = 15     # An agent this recently started is still loading config
$ConfigFreshMinutes   = 15     # Config downloaded this recently means a load burst is expected
$ServiceStopTimeoutS  = 60
$ServiceStartTimeoutS = 90
$MaxRuntimeMinutes    = 10     # Self-enforced deadline

$Deadline = (Get-Date).AddMinutes($MaxRuntimeMinutes)

# -- WhatIf bridge --
$WhatIfPreference = $false
if ($env:WhatIf) {
    try   { $WhatIfPreference = [System.Convert]::ToBoolean($env:WhatIf) }
    catch { $WhatIfPreference = $false }
}

Write-Host "[$RunEventId] Executing Invoke-AutoRemediateSCOMMonitoringHost payload, $SCRIPT_VERSION. Started @ '$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))'  WhatIf=$WhatIfPreference"
Write-Log "Payload started. WhatIf=$WhatIfPreference"

$mutex = $null
$owned = $false

try {
    $mutex = New-Object System.Threading.Mutex($false, $MutexName)
    try {
        $owned = $mutex.WaitOne(0)
    }
    catch [System.Threading.AbandonedMutexException] {
        $owned = $true
        Write-Log 'Acquired abandoned mutex; a previous run terminated unexpectedly.' -Level 'WARN'
    }

    if (-not $owned) {
        Write-Output "$HEAD Another instance holds the lock. Exiting."
        Write-Log 'Another instance holds the lock. Exiting.'
        exit 0
    }

    # Guarded: this marker is progress reporting, not state the run depends on. If the
    # key is unwritable the run should still proceed and report its findings, rather
    # than dumping raw PowerShell errors into the UEM console output where they bury
    # the actual result.
    try {
        # -ErrorAction Stop on both: a registry PermissionDenied is a NON-terminating
        # error, so without it the failure sails straight past this catch and prints
        # a raw PowerShell error instead of being handled.
        if (-not (Test-Path $RegPath)) { New-Item -Path $RegPath -Force -ErrorAction Stop -WhatIf:$false | Out-Null }
        Set-ItemProperty -Path $RegPath -Name 'Status' -Value 'Running' -Type String -ErrorAction Stop -WhatIf:$false
    }
    catch {
        Write-Log "Could not write the Running marker to $RegPath -- $($_.Exception.Message)" -Level 'WARN'
    }

    # -- Cooldown gate --
    $last = (Get-ItemProperty -Path $RegPath -Name 'LastRecycleTime' -ErrorAction SilentlyContinue).LastRecycleTime
    if ($last) {
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParse($last, [ref]$parsed)) {
            if ((Get-Date) -lt $parsed.AddHours($MinIntervalHours)) {
                Write-Output "$HEAD Recycled at $parsed, within the ${MinIntervalHours}h cooldown. Skipping."
                Write-Log "Within cooldown (last recycle $parsed). Skipping."
                Set-ItemProperty -Path $RegPath -Name 'Status'      -Value 'SkippedCooldown'       -Type String -ErrorAction Stop -WhatIf:$false
                Set-ItemProperty -Path $RegPath -Name 'LastRunTime' -Value (Get-Date -Format 'o')  -Type String -ErrorAction Stop -WhatIf:$false
                exit 0
            }
        }
    }

    # -- Agent discovery --
    $agentRoot = $null
    foreach ($candidate in @('HKLM:\SOFTWARE\Microsoft\Microsoft Operations Manager\3.0',
                             'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Microsoft Operations Manager\3.0')) {
        if (Test-Path $candidate) { $agentRoot = $candidate; break }
    }

    $installDir = ''
    if ($agentRoot) {
        $setup = Get-ItemProperty -Path (Join-Path $agentRoot 'Setup') -ErrorAction SilentlyContinue
        if ($setup -and $setup.InstallDirectory) { $installDir = [string]$setup.InstallDirectory }
    }
    $ConfigDir = if ($installDir) { Join-Path $installDir 'Health Service State\Connector Configuration Cache' } else { '' }

    # -- Shared state --
    $Script:AbortRecycle   = $false
    $Script:BlockReason    = ''
    $Script:Recycled       = $false
    $Script:CpuPercent     = -1
    $Script:MemoryMB       = -1
    $Script:HostCount      = -1
    $Script:TopOffender    = ''
    $Script:MemoryAfterMB  = -1

    # Interval CPU across the agent's processes, expressed as a share of the whole
    # machine. Two TotalProcessorTime reads a known interval apart -- accurate, and
    # far cheaper than a performance counter subscription.
    function Get-AgentLoadSample {
        $procs = @(Get-Process -Name 'HealthService', 'MonitoringHost' -ErrorAction SilentlyContinue)
        $cpu   = 0.0
        foreach ($p in $procs) {
            try { $cpu += $p.TotalProcessorTime.TotalSeconds } catch { }
        }
        return [PSCustomObject]@{
            Taken     = Get-Date
            CpuSecond = $cpu
            MemoryMB  = if ($procs.Count -gt 0) { [math]::Round((($procs | Measure-Object -Property WorkingSet64 -Sum).Sum) / 1MB) } else { 0 }
            HostCount = @($procs | Where-Object { $_.ProcessName -eq 'MonitoringHost' }).Count
            Processes = $procs
        }
    }

# Compact result constructor -- see the long-form note in Invoke-AutoRemediateSCOMAgent.ps1.
    function Res { param([string]$S, [string]$M) return @{ Status = $S; Message = $M } }
        # -- Step Definitions --
    # Fields: Name, DetectionScript, and ResolutionScript where the step acts.
    # Optional: Enabled = $false to ship a step disabled; ResolveOnWarning = $true
    # to remediate on Warning as well as Failed. Execution order is array order.
    $Steps = @(

        @{
            Name             = 'Agent Present Guard'
            DetectionScript  = {
                if (-not $agentRoot) {
                    $Script:AbortRecycle = $true
                    $Script:BlockReason  = 'NoAgent'
                    return Res Warning 'No Operations Manager agent installed -- nothing to recycle'
                }
                $svc = Get-Service -Name 'HealthService' -ErrorAction SilentlyContinue
                if (-not $svc -or $svc.Status -ne 'Running') {
                    $Script:AbortRecycle = $true
                    $Script:BlockReason  = 'ServiceNotRunning'
                    return Res Warning "HealthService is $(if ($svc) { $svc.Status } else { 'not installed' }) -- a stopped agent consumes nothing; use Invoke-AutoRemediateSCOMAgent.ps1 to start it"
                }
                return Res Passed 'Agent installed and running'
            }
        },

        @{
            Name             = 'Configuration Activity Guard'
            DetectionScript  = {
                if ($Script:AbortRecycle) {
                    return Res Passed 'Skipped -- blocked by an earlier gate'
                }

                # High CPU immediately after a start or a config refresh is the agent
                # loading and initialising workflows. That is the expected cost of
                # doing its job, and recycling restarts the same work from zero.
                $proc = Get-Process -Name 'HealthService' -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($proc) {
                    try {
                        $upMin = [math]::Round(((Get-Date) - $proc.StartTime).TotalMinutes)
                        if ($upMin -lt $RecentStartMinutes) {
                            $Script:AbortRecycle = $true
                            $Script:BlockReason  = 'AgentRecentlyStarted'
                            return Res Warning "Aborting -- agent started ${upMin}m ago (threshold ${RecentStartMinutes}m); it is still loading workflows"
                        }
                    }
                    catch { }
                }

                if ($ConfigDir -and (Test-Path -LiteralPath $ConfigDir)) {
                    $cfg = Get-ChildItem -Path $ConfigDir -Filter 'OpsMgrConnector.Config.xml' -Recurse -File -ErrorAction SilentlyContinue |
                           Sort-Object LastWriteTime -Descending | Select-Object -First 1
                    if ($cfg) {
                        $cfgAgeMin = [math]::Round(((Get-Date) - $cfg.LastWriteTime).TotalMinutes)
                        if ($cfgAgeMin -lt $ConfigFreshMinutes) {
                            $Script:AbortRecycle = $true
                            $Script:BlockReason  = 'ConfigurationJustApplied'
                            return Res Warning "Aborting -- new configuration applied ${cfgAgeMin}m ago (threshold ${ConfigFreshMinutes}m); the load burst is expected"
                        }
                    }
                }

                return Res Passed 'Agent is past its startup and configuration load window'
            }
        },

        @{
            Name             = 'Sustained Load Confirmation'
            DetectionScript  = {
                if ($Script:AbortRecycle) {
                    return Res Passed 'Skipped -- blocked by an earlier gate'
                }

                $cores = [int](Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue).NumberOfLogicalProcessors
                if ($cores -lt 1) { $cores = 1 }

                $s1 = Get-AgentLoadSample
                Start-Sleep -Seconds $SampleIntervalSecs
                $s2 = Get-AgentLoadSample

                $elapsed = ($s2.Taken - $s1.Taken).TotalSeconds
                if ($elapsed -le 0) {
                    $Script:AbortRecycle = $true
                    $Script:BlockReason  = 'SampleFailed'
                    return Res Warning 'Aborting -- load sampling produced no usable interval'
                }

                $Script:CpuPercent = [math]::Round(((($s2.CpuSecond - $s1.CpuSecond) / $elapsed) / $cores) * 100, 1)
                $Script:MemoryMB   = [math]::Max($s1.MemoryMB, $s2.MemoryMB)
                $Script:HostCount  = $s2.HostCount

                # Identify the heaviest MonitoringHost for the report. The loaded
                # workflow is not readable from outside the process, so this is as
                # specific as an endpoint script can honestly be -- PID and identity,
                # which is enough for the management pack owner to correlate.
                $top = $s2.Processes | Where-Object { $_.ProcessName -eq 'MonitoringHost' } |
                       Sort-Object WorkingSet64 -Descending | Select-Object -First 1
                if ($top) {
                    $owner = ''
                    try {
                        $cim = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$($top.Id)" -ErrorAction SilentlyContinue
                        if ($cim) {
                            $o = Invoke-CimMethod -InputObject $cim -MethodName GetOwner -ErrorAction SilentlyContinue
                            if ($o -and $o.User) { $owner = "$($o.Domain)\$($o.User)" }
                        }
                    }
                    catch { }
                    $Script:TopOffender = "PID $($top.Id), $([math]::Round($top.WorkingSet64 / 1MB))MB$(if ($owner) { ", running as $owner" })"
                }

                $cpuHigh = $Script:CpuPercent -gt $CpuWarnPercent
                $memHigh = $Script:MemoryMB   -gt $MemoryWarnMB

                if (-not $cpuHigh -and -not $memHigh) {
                    $Script:AbortRecycle = $true
                    $Script:BlockReason  = 'LoadWithinThreshold'
                    return Res Passed "Load is within threshold over a ${elapsed}s interval: $($Script:CpuPercent)% CPU (limit ${CpuWarnPercent}%), $($Script:MemoryMB)MB (limit ${MemoryWarnMB}MB) across $($Script:HostCount) MonitoringHost instance(s). No action."
                }

                $breach = @()
                if ($cpuHigh) { $breach += "$($Script:CpuPercent)% CPU over ${elapsed}s (limit ${CpuWarnPercent}%)" }
                if ($memHigh) { $breach += "$($Script:MemoryMB)MB working set (limit ${MemoryWarnMB}MB)" }

                return Res Passed "Sustained load confirmed: $($breach -join '; '); heaviest instance $($Script:TopOffender)"
            }
        },

        @{
            Name             = 'Agent Recycle'
            DetectionScript  = {
                if ($Script:AbortRecycle) {
                    return Res Passed "Skipped -- blocked by an earlier gate ($($Script:BlockReason)); the agent was not restarted"
                }
                return Res Failed "Recycling HealthService to clear the runaway workflow ($($Script:CpuPercent)% CPU, $($Script:MemoryMB)MB)"
            }
            ResolutionScript = {
                if ((Get-Date) -gt $Deadline) {
                    Write-Log 'Deadline exceeded before the recycle began - aborting.' -Level 'ERROR'
                    Set-ItemProperty -Path $RegPath -Name 'Status' -Value 'TimedOut' -Type String -ErrorAction Stop -WhatIf:$false
                    return
                }

                if (-not $PSCmdlet.ShouldProcess('HealthService', 'Stop and restart the agent service')) { return }

                # Graceful stop. Stop-Process on MonitoringHost would orphan the
                # children HealthService is tracking and can leave the state store
                # mid-write; the service control path shuts workflows down cleanly.
                $svc = Get-Service -Name 'HealthService' -ErrorAction SilentlyContinue
                Stop-Service -Name 'HealthService' -Force -ErrorAction SilentlyContinue
                try {
                    $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds($ServiceStopTimeoutS))
                }
                catch {
                    Write-Log "HealthService did not stop within ${ServiceStopTimeoutS}s; starting it again regardless." -Level 'WARN'
                }

                # sc.exe returns at START_PENDING rather than blocking on the SCM.
                & sc.exe start HealthService | Out-Null
                $Script:Recycled = $true
                Write-Log 'Recycled HealthService.'
            }
        },

        @{
            Name             = 'Post-Recycle Verification'
            # Report only
            DetectionScript  = {
                if (-not $Script:Recycled) {
                    return Res Passed 'No recycle performed -- nothing to verify'
                }

                $svc = Get-Service -Name 'HealthService' -ErrorAction SilentlyContinue
                if (-not $svc) {
                    return Res Failed 'HealthService is missing after the recycle -- escalate immediately'
                }
                try {
                    $svc.WaitForStatus('Running', [TimeSpan]::FromSeconds($ServiceStartTimeoutS))
                }
                catch {
                    return Res Failed "HealthService did not return to Running within ${ServiceStartTimeoutS}s -- the device is now unmonitored; escalate immediately"
                }

                $after = Get-AgentLoadSample
                $Script:MemoryAfterMB = $after.MemoryMB

                return Res Passed "Agent recycled and running: working set $($Script:MemoryMB)MB -> $($Script:MemoryAfterMB)MB. NOTE: this treats the symptom. The offending workflow ($($Script:TopOffender)) will reload with the configuration -- report it to the management pack owner or the load will return."
            }
        }
    )

    # -- Execution Engine --
    $activeSteps = $Steps |
        Where-Object { -not $_.ContainsKey('Enabled') -or $_.Enabled }

    $results = [System.Collections.Generic.List[PSCustomObject]]::new()

    Write-Host "`n-- SCOMMonitoringHostResolutionWizard ----------------------------" -ForegroundColor Cyan
    Write-Host "   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')   Steps: $($activeSteps.Count)"
    Write-Host '----------------------------------------------------------------' -ForegroundColor Cyan

    $stepIndex = 0
    foreach ($step in $activeSteps) {
        $stepIndex++

        $status     = 'Failed'
        $message    = 'Detection script did not return a result.'
        $remediated = $false
        $remError   = ''

        try {
            $result  = & $step.DetectionScript
            $status  = $result.Status
            $message = $result.Message
        }
        catch {
            $status  = 'Failed'
            $message = "Detection exception: $($_.Exception.Message)"
        }

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
    Write-Host "----------------------------------------------------------------`n" -ForegroundColor Cyan

    # -- Persist results for DEX sensors --
    try {
        $overall = if ($failed -gt 0)             { 'Failed' }
                   elseif ($Script:Recycled)      { 'Recycled' }
                   elseif ($Script:BlockReason)   { "Skipped:$($Script:BlockReason)" }
                   else                           { 'Completed' }

        Set-ItemProperty -Path $RegPath -Name 'Status'         -Value $overall                       -Type String -ErrorAction Stop -WhatIf:$false
        Set-ItemProperty -Path $RegPath -Name 'LastRunTime'    -Value (Get-Date -Format 'o')         -Type String -ErrorAction Stop -WhatIf:$false
        Set-ItemProperty -Path $RegPath -Name 'ScriptVersion'  -Value $SCRIPT_VERSION                -Type String -ErrorAction Stop -WhatIf:$false
        Set-ItemProperty -Path $RegPath -Name 'Recycled'       -Value ([int]$Script:Recycled)        -Type DWord  -ErrorAction Stop -WhatIf:$false
        Set-ItemProperty -Path $RegPath -Name 'CpuPercent'     -Value ([string]$Script:CpuPercent)   -Type String -ErrorAction Stop -WhatIf:$false
        Set-ItemProperty -Path $RegPath -Name 'MemoryMB'       -Value ([string]$Script:MemoryMB)     -Type String -ErrorAction Stop -WhatIf:$false
        Set-ItemProperty -Path $RegPath -Name 'MemoryAfterMB'  -Value ([string]$Script:MemoryAfterMB) -Type String -ErrorAction Stop -WhatIf:$false
        Set-ItemProperty -Path $RegPath -Name 'HostCount'      -Value ([string]$Script:HostCount)    -Type String -ErrorAction Stop -WhatIf:$false
        Set-ItemProperty -Path $RegPath -Name 'TopOffender'    -Value $Script:TopOffender            -Type String -ErrorAction Stop -WhatIf:$false
        Set-ItemProperty -Path $RegPath -Name 'BlockReason'    -Value $Script:BlockReason            -Type String -ErrorAction Stop -WhatIf:$false

        if ($Script:Recycled) {
            Set-ItemProperty -Path $RegPath -Name 'LastRecycleTime' -Value (Get-Date -Format 'o') -Type String -ErrorAction Stop -WhatIf:$false
        }
    }
    catch {
        Write-Log "Failed to cache results: $($_.Exception.Message)" -Level 'ERROR'
    }

    Write-Log 'Payload complete.'

    if ($failed -gt 0) { exit 1 }
    exit 0
}
catch {
    Write-Error "$HEAD ERROR: $($_.Exception.Message)"
    Write-Log "ERROR: $($_.Exception.Message)" -Level 'ERROR'
    try {
        if (-not (Test-Path $RegPath)) { New-Item -Path $RegPath -Force -ErrorAction Stop -WhatIf:$false | Out-Null }
        Set-ItemProperty -Path $RegPath -Name 'Status'      -Value 'Failed'               -Type String -ErrorAction Stop -WhatIf:$false
        Set-ItemProperty -Path $RegPath -Name 'LastRunTime' -Value (Get-Date -Format 'o') -Type String -ErrorAction Stop -WhatIf:$false
    }
    catch { }
    exit 1
}
finally {
    # Self-cleanup, but only from the instance that actually held the lock.
    # Unregistering from a lock-loser would stop the task the winner is running in.
    if ($owned) {
        if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        }
        $mutex.ReleaseMutex()
    }
    if ($mutex) { $mutex.Dispose() }
}
