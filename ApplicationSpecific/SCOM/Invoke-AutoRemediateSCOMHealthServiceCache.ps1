#Requires -Version 5.1
<#
.SYNOPSIS
    SCOMHealthServiceCacheResolutionWizard -- Flush the Operations Manager agent state cache. DESTRUCTIVE.

.DESCRIPTION
    Split out of Invoke-AutoRemediateSCOMAgent.ps1 deliberately. Deploying THIS script
    is the opt-in -- do not fold it back into a general health sweep.

    Six steps: 1 Admin Confirmation Gate, 2 Agent and Install Guard, 3 Management
    Server Reachability, 4 Flush Signal Confirmation, 5 Health Service State Flush,
    6 Post-Flush Verification. Steps 1-4 are all abort gates and ALL must pass.

    Step 3 is not optional: an agent that cannot reach its management server at the
    moment of the flush is left with no configuration and no way to obtain one. Step 4
    requires a real signal (stale config, ESENT corruption, oversized folder) -- age
    alone is not a reason. The state folder is RENAMED, not deleted, and restored
    automatically if the agent fails to come back; deletion happens only after step 6
    confirms recovery. A cooldown marker prevents repeat flushes on one device.

    >> Everything else -- why this is never run fleet-wide, the management-group load
       cost, the permanently-discarded unsent data, the shared-folder interaction with
       the Log Analytics side of a multi-homed MMA, the AV/EDR exclusion this launcher
       requires, rollout guidance and tunables -- is in
       ApplicationSpecific/SCOM/README.md sections 3, 6.1 and 10. Read before deploying.

.NOTES
    Script Name  : Invoke-AutoRemediateSCOMHealthServiceCache.ps1
    Version      : 1.0.0
    Architecture : x64
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-25
    Timeout      : ~5 seconds (launcher exits immediately; payload runs via scheduled task, self-capped at 15 minutes)

    Environment variables:
      ConfirmHighImpact = true   REQUIRED. Absent/unparseable => nothing is flushed.
      WhatIf            = true   Dry run. Absent/unparseable => live run.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param([switch]$RunAsPayload)

$SCRIPT_VERSION = '1.0.0'

# -- Dispatch constants (launcher + payload) --
$TaskName   = 'WS1_SCOMHealthServiceCache'
$MutexName  = 'Global\WS1_DEX_SCOMHealthServiceCache'
$BaseDir    = Join-Path $env:ProgramData 'AirWatch\Extensions\SCOM'
$PayloadPs1 = Join-Path $BaseDir 'Invoke-AutoRemediateSCOMHealthServiceCache.ps1'
$RegPath    = 'HKLM:\Software\AirWatch\Extensions\SCOM\HealthServiceCache'
$LogPath    = "$env:SystemRoot\Temp\UEM_AutoRemediateSCOMHealthServiceCache.log"

$RunEventId = ([Random]::new()).Next(1000, 9999)
$HEAD       = "`r`n[$RunEventId]"

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    "[$timestamp] [$RunEventId] [$Level] $Message" |
        Out-File -FilePath $LogPath -Append -Encoding UTF8 -WhatIf:$false -ErrorAction SilentlyContinue
}

# -- Launcher (UEM dispatcher) --
# UEM runs this WITHOUT -RunAsPayload; the launcher stages the script and`n# dispatches a task to re-run it. README section 3.
if (-not $RunAsPayload) {
    try {
        # Layer 1 gate -- cheap, mechanism-specific.
        $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($existing -and $existing.State -eq 'Running') {
            Write-Output "$HEAD Payload already running. Skipping dispatch."
            exit 0
        }

        if (-not (Test-Path $BaseDir)) {
            New-Item -ItemType Directory -Path $BaseDir -Force -ErrorAction Stop -WhatIf:$false | Out-Null
        }

        # UEM deletes its temp copy; stage one for the task.
        Copy-Item -Path $PSCommandPath -Destination $PayloadPs1 -Force -ErrorAction Stop -WhatIf:$false

        # Stamp 'Dispatched' so sensors have a value early.
        if (-not (Test-Path $RegPath)) { New-Item -Path $RegPath -Force -ErrorAction Stop -WhatIf:$false | Out-Null }
        Set-ItemProperty -Path $RegPath -Name 'Status'           -Value 'Dispatched'           -Type String -ErrorAction Stop -WhatIf:$false
        Set-ItemProperty -Path $RegPath -Name 'LastDispatchTime' -Value (Get-Date -Format 'o')  -Type String -ErrorAction Stop -WhatIf:$false

        if ($existing) {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        }

        $action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
                         -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$PayloadPs1`" -RunAsPayload"
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings  = New-ScheduledTaskSettingsSet `
                         -ExecutionTimeLimit '00:20:00' `
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
#  Payload runs below, in the scheduled task context.
# -- Tunables --
# Hard-coded -- fork the script object per ring. See README section 10.
$ConfigStaleHours     = 24     # Config cache untouched this long is a signal
$StateFolderWarnMB    = 1536   # State folder above this counts as a signal
$MinIntervalDays      = 7      # Cooldown between flushes on one device
$ServiceStopTimeoutS  = 60     # How long to wait for HealthService to stop
$ServiceStartTimeoutS = 60     # How long to wait for HealthService to start
$ConfigWaitSeconds    = 300    # Wait for configuration re-download
$ConfigPollSeconds    = 15     # Poll interval while waiting for configuration
$BackupRetentionHours = 24     # Leftover backups older than this are cleaned up
$MaxRuntimeMinutes    = 15     # Self-enforced deadline
$NetTimeoutMs         = 5000   # Socket timeout for the management server probe

$Deadline = (Get-Date).AddMinutes($MaxRuntimeMinutes)

# -- WhatIf bridge --
$WhatIfPreference = $false
if ($env:WhatIf) {
    try   { $WhatIfPreference = [System.Convert]::ToBoolean($env:WhatIf) }
    catch { $WhatIfPreference = $false }
}

# -- Admin confirmation gate --
# FAILS CLOSED: absent or unparseable => do not proceed.
$ConfirmHighImpact = $false
if ($env:ConfirmHighImpact) {
    try   { $ConfirmHighImpact = [System.Convert]::ToBoolean($env:ConfirmHighImpact) }
    catch { $ConfirmHighImpact = $false }
}

Write-Host "[$RunEventId] Executing Invoke-AutoRemediateSCOMHealthServiceCache payload, $SCRIPT_VERSION. Started @ '$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))'  WhatIf=$WhatIfPreference  ConfirmHighImpact=$ConfirmHighImpact"
Write-Log "Payload started. WhatIf=$WhatIfPreference ConfirmHighImpact=$ConfirmHighImpact"

# -- Layer 2 concurrency lock --
# Kernel-managed: released on process death; no stale-lock mode.
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

    # Progress marker; an unwritable key must not stop the run.
    try {
        # -ErrorAction Stop: a registry PermissionDenied is NON-terminating.
        if (-not (Test-Path $RegPath)) { New-Item -Path $RegPath -Force -ErrorAction Stop -WhatIf:$false | Out-Null }
        Set-ItemProperty -Path $RegPath -Name 'Status' -Value 'Running' -Type String -ErrorAction Stop -WhatIf:$false
    }
    catch {
        Write-Log "Could not write the Running marker to $RegPath -- $($_.Exception.Message)" -Level 'WARN'
    }

    # -- Cooldown gate --
    # Mutex = "another copy running?"; this = "did it run recently?".
    $last = (Get-ItemProperty -Path $RegPath -Name 'LastRunTime' -ErrorAction SilentlyContinue).LastRunTime
    if ($last) {
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParse($last, [ref]$parsed)) {
            if ((Get-Date) -lt $parsed.AddDays($MinIntervalDays)) {
                Write-Output "$HEAD Flushed at $parsed, within the ${MinIntervalDays}-day cooldown. Skipping."
                Write-Log "Within cooldown (last run $parsed). Skipping."
                Set-ItemProperty -Path $RegPath -Name 'Status' -Value 'SkippedCooldown' -Type String -ErrorAction Stop -WhatIf:$false
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

    $StateDir   = if ($installDir) { Join-Path $installDir 'Health Service State' } else { '' }
    $ConfigDir  = if ($StateDir)   { Join-Path $StateDir 'Connector Configuration Cache' } else { '' }
    $BackupRoot = $installDir

    Write-Log "AgentRoot: $agentRoot | InstallDir: $installDir | StateDir: $StateDir"

    # -- Housekeeping: clear leftover backups --
    if ($BackupRoot -and (Test-Path -LiteralPath $BackupRoot)) {
        $stale = @(Get-ChildItem -LiteralPath $BackupRoot -Directory -Filter 'Health Service State.dexbak-*' -ErrorAction SilentlyContinue |
                   Where-Object { $_.CreationTime -lt (Get-Date).AddHours(-$BackupRetentionHours) })
        foreach ($s in $stale) {
            Remove-Item -LiteralPath $s.FullName -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "Removed stale backup: $($s.Name)"
        }
    }

    # -- Shared state --
    $Script:AbortFlush     = $false
    $Script:BackupPath     = ''
    $Script:Flushed        = $false
    $Script:Restored       = $false
    $Script:ReclaimedMB    = 0
    $Script:StateFolderMB  = -1
    $Script:BlockReason    = ''

    function Get-FolderSizeMB {
        param([string]$Path)
        if ([string]::IsNullOrEmpty($Path) -or -not (Test-Path -LiteralPath $Path)) { return -1 }
        $sizeMB = -1
        $fso    = $null
        try {
            $fso    = New-Object -ComObject Scripting.FileSystemObject
            $sizeMB = [math]::Round($fso.GetFolder($Path).Size / 1MB, 1)
        }
        catch { $sizeMB = -1 }
        finally { if ($fso) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($fso) } }
        return $sizeMB
    }

# Result constructor -- see Invoke-AutoRemediateSCOMAgent.ps1.
    function Res { param([string]$S, [string]$M) return @{ Status = $S; Message = $M } }
        # -- Step Definitions --
    # Fields: Name, DetectionScript, ResolutionScript (where it acts).
    # Optional: Enabled = $false, ResolveOnWarning = $true.
    # Execution order is array order.
    $Steps = @(

        @{
            Name             = 'Admin Confirmation Gate'
            DetectionScript  = {
                if (-not $ConfirmHighImpact) {
                    $Script:AbortFlush  = $true
                    $Script:BlockReason = 'NotConfirmed'
                    # Detection still runs and reports -- that is how an admin decides.
                    return Res Warning "Not confirmed -- set ConfirmHighImpact to 'true' on the script object to allow the flush. Detection below is for review; nothing will be changed."
                }
                return Res Passed 'High-impact action confirmed by the administrator'
            }
        },

        @{
            Name             = 'Agent and Install Guard'
            DetectionScript  = {
                if (-not $agentRoot -or -not $installDir) {
                    $Script:AbortFlush  = $true
                    $Script:BlockReason = 'NoAgent'
                    return Res Warning 'No Operations Manager agent installed -- nothing to flush'
                }
                if (-not (Test-Path -LiteralPath $StateDir)) {
                    $Script:AbortFlush  = $true
                    $Script:BlockReason = 'NoStateFolder'
                    return Res Warning "Health Service State folder not present at '$StateDir' -- nothing to flush"
                }

                # Flushing under a running install or upgrade produces a
                # half-configured agent that neither process can recover.
                $blockers = @()
                foreach ($p in 'MOMAgentInstaller', 'ccmsetup', 'TrustedInstaller') {
                    if (Get-Process -Name $p -ErrorAction SilentlyContinue) { $blockers += "$p.exe" }
                }
                if ($blockers.Count -gt 0) {
                    $Script:AbortFlush  = $true
                    $Script:BlockReason = 'InstallInProgress'
                    return Res Warning "Aborting -- install or servicing in progress: $($blockers -join ', ')"
                }

                $Script:StateFolderMB = Get-FolderSizeMB -Path $StateDir
                return Res Passed "Agent present, state folder is $($Script:StateFolderMB)MB, no install in progress"
            }
        },

        @{
            Name             = 'Management Server Reachability'
            DetectionScript  = {
                if ($Script:AbortFlush) {
                    return Res Passed 'Skipped -- blocked by an earlier gate'
                }

                $parent = $null
                $mgRoot = Join-Path $agentRoot 'Agent Management Groups'
                foreach ($g in @(Get-ChildItem -Path $mgRoot -ErrorAction SilentlyContinue)) {
                    foreach ($p in @(Get-ChildItem -Path (Join-Path $g.PSPath 'Parent Health Services') -ErrorAction SilentlyContinue)) {
                        $props = Get-ItemProperty -Path $p.PSPath -ErrorAction SilentlyContinue
                        if ($props -and $props.NetworkName) {
                            $parent = [PSCustomObject]@{
                                Network = [string]$props.NetworkName
                                Port    = if ($props.Port) { [int]$props.Port } else { 5723 }
                            }
                            break
                        }
                    }
                    if ($parent) { break }
                }

                if (-not $parent) {
                    $Script:AbortFlush  = $true
                    $Script:BlockReason = 'NoManagementServer'
                    return Res Warning 'Aborting -- no parent management server assigned. A flushed agent with nowhere to fetch configuration stops monitoring permanently.'
                }

                # WaitOne() alone is not sufficient: it also returns true when the
                # connect completed with a refusal. EndConnect() throws in that case,
                # which is what actually distinguishes reachable from refused.
                $reachable = $false
                $tcp = New-Object System.Net.Sockets.TcpClient
                try {
                    $ar = $tcp.BeginConnect($parent.Network, $parent.Port, $null, $null)
                    if ($ar.AsyncWaitHandle.WaitOne($NetTimeoutMs, $false)) {
                        $tcp.EndConnect($ar)
                        $reachable = $tcp.Connected
                    }
                }
                catch { }
                finally { $tcp.Close() }

                if (-not $reachable) {
                    $Script:AbortFlush  = $true
                    $Script:BlockReason = 'ManagementServerUnreachable'
                    return Res Warning "Aborting -- management server $($parent.Network):$($parent.Port) is unreachable. GATE NOT OPTIONAL: flushing now leaves the agent with no configuration and no way to get it. Re-run on-network."
                }

                return Res Passed "Management server $($parent.Network):$($parent.Port) reachable -- the agent can re-provision after the flush"
            }
        },

        @{
            Name             = 'Flush Signal Confirmation'
            DetectionScript  = {
                if ($Script:AbortFlush) {
                    return Res Passed 'Skipped -- blocked by an earlier gate'
                }

                $signals = @()

                # Signal 1: configuration cache is stale.
                if ($ConfigDir -and (Test-Path -LiteralPath $ConfigDir)) {
                    $config = Get-ChildItem -Path $ConfigDir -Filter 'OpsMgrConnector.Config.xml' -Recurse -File -ErrorAction SilentlyContinue |
                              Sort-Object LastWriteTime -Descending | Select-Object -First 1
                    if (-not $config) {
                        $signals += 'no configuration file present'
                    }
                    else {
                        $ageH = [math]::Round(((Get-Date) - $config.LastWriteTime).TotalHours, 1)
                        if ($ageH -gt $ConfigStaleHours) { $signals += "configuration ${ageH}h stale" }
                    }
                }
                else {
                    $signals += 'configuration cache folder missing'
                }

                # Signal 2: eSENT corruption against the agent's own store. Own
                # try/catch -- ProviderName + Id + StartTime in one filter hashtable
                # can throw a terminating error when the provider is unregistered.
                try {
                    $esent = @(Get-WinEvent -FilterHashtable @{
                        LogName      = 'Application'
                        ProviderName = 'ESENT'
                        Id           = 477, 490, 623
                        StartTime    = (Get-Date).AddHours(-24)
                    } -MaxEvents 200 -ErrorAction SilentlyContinue |
                    Where-Object { $_.Message -match 'HealthServiceStore|Health Service State' })
                    if ($esent.Count -gt 0) { $signals += "$($esent.Count) ESENT error(s) against the state store" }
                }
                catch {
                    Write-Log "ESENT event query failed: $($_.Exception.Message)" -Level 'WARN'
                }

                # Signal 3: the folder itself is oversized.
                if ($Script:StateFolderMB -gt $StateFolderWarnMB) {
                    $signals += "state folder $($Script:StateFolderMB)MB over the ${StateFolderWarnMB}MB threshold"
                }

                if ($signals.Count -eq 0) {
                    $Script:AbortFlush  = $true
                    $Script:BlockReason = 'NoSignal'
                    return Res Passed 'No flush signal -- configuration current, store healthy, folder within size. No action.'
                }

                return Res Passed "Flush signal(s) confirmed: $($signals -join '; ')"
            }
        },

        @{
            Name             = 'Health Service State Flush'
            DetectionScript  = {
                if ($Script:AbortFlush) {
                    return Res Passed "Skipped -- blocked by an earlier gate ($($Script:BlockReason)); nothing was deleted"
                }
                return Res Failed "All gates cleared -- flushing $($Script:StateFolderMB)MB of agent state"
            }
            ResolutionScript = {
                if ((Get-Date) -gt $Deadline) {
                    Write-Log 'Deadline exceeded before the flush began - aborting.' -Level 'ERROR'
                    Set-ItemProperty -Path $RegPath -Name 'Status' -Value 'TimedOut' -Type String -ErrorAction Stop -WhatIf:$false
                    return
                }

                if (-not $PSCmdlet.ShouldProcess($StateDir, 'Stop HealthService and rename the state folder')) { return }

                # Stop first. Renaming a folder the service holds open fails, and a
                # partial rename is worse than no rename.
                $svc = Get-Service -Name 'HealthService' -ErrorAction SilentlyContinue
                if ($svc -and $svc.Status -ne 'Stopped') {
                    Stop-Service -Name 'HealthService' -Force -ErrorAction SilentlyContinue
                    try {
                        $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds($ServiceStopTimeoutS))
                    }
                    catch {
                        Write-Log "HealthService did not stop within ${ServiceStopTimeoutS}s - aborting flush." -Level 'ERROR'
                        $Script:BlockReason = 'ServiceWouldNotStop'
                        & sc.exe start HealthService | Out-Null
                        return
                    }
                }

                # Rename rather than delete. If the agent does not come back, step 6
                # restores this folder and the device is no worse off.
                $Script:BackupPath = Join-Path $installDir ("Health Service State.dexbak-{0}" -f (Get-Date -Format 'yyyyMMddHHmmss'))
                try {
                    Rename-Item -LiteralPath $StateDir -NewName (Split-Path $Script:BackupPath -Leaf) -ErrorAction Stop
                    $Script:Flushed = $true
                    Write-Log "Renamed state folder to '$($Script:BackupPath)'."
                }
                catch {
                    Write-Log "Rename failed: $($_.Exception.Message)" -Level 'ERROR'
                    $Script:BackupPath  = ''
                    $Script:BlockReason = 'RenameFailed'
                    & sc.exe start HealthService | Out-Null
                    return
                }

                & sc.exe start HealthService | Out-Null
                Write-Log 'Issued start for HealthService after the flush.'
            }
        },

        @{
            Name             = 'Post-Flush Verification'
            # Report only -- rollback is handled inline below
            DetectionScript  = {
                if (-not $Script:Flushed) {
                    return Res Passed 'No flush performed -- nothing to verify'
                }

                # Wait for the service to come up.
                $svc     = Get-Service -Name 'HealthService' -ErrorAction SilentlyContinue
                $started = $false
                if ($svc) {
                    try {
                        $svc.WaitForStatus('Running', [TimeSpan]::FromSeconds($ServiceStartTimeoutS))
                        $started = $true
                    }
                    catch { $started = $false }
                }

                if (-not $started) {
                    $Script:Restored = Restore-StateFolder
                    return Res Failed "HealthService did not start within ${ServiceStartTimeoutS}s after the flush -- state folder $(if ($Script:Restored) { 'restored' } else { 'NOT restored, escalate now' })"
                }

                # Wait for the agent to pull configuration back down. Until this
                # happens the agent is running but monitoring nothing.
                $configBack = $false
                $waitUntil  = (Get-Date).AddSeconds($ConfigWaitSeconds)
                while ((Get-Date) -lt $waitUntil -and (Get-Date) -lt $Deadline) {
                    if ($ConfigDir -and (Test-Path -LiteralPath $ConfigDir)) {
                        $cfg = Get-ChildItem -Path $ConfigDir -Filter 'OpsMgrConnector.Config.xml' -Recurse -File -ErrorAction SilentlyContinue |
                               Select-Object -First 1
                        if ($cfg) { $configBack = $true; break }
                    }
                    Start-Sleep -Seconds $ConfigPollSeconds
                }

                if (-not $configBack) {
                    $Script:Restored = Restore-StateFolder
                    return Res Failed "Agent started but received no configuration within ${ConfigWaitSeconds}s -- state folder $(if ($Script:Restored) { 'restored' } else { 'NOT restored, escalate now' }). The MS may be refusing this agent; check event 21016."
                }

                # Recovery confirmed. Only now is the old state safe to delete.
                $Script:ReclaimedMB = Get-FolderSizeMB -Path $Script:BackupPath
                Remove-Item -LiteralPath $Script:BackupPath -Recurse -Force -ErrorAction SilentlyContinue
                $backupGone = -not (Test-Path -LiteralPath $Script:BackupPath)
                if ($backupGone) { $Script:BackupPath = '' }

                $note = if ($backupGone) { "reclaimed ~$($Script:ReclaimedMB)MB" }
                        else { "old state left at '$($Script:BackupPath)' for manual removal" }

                return Res Passed "Agent recovered: service running and configuration re-downloaded; $note"
            }
        }
    )

    # -- Rollback helper --
    function Restore-StateFolder {
        if (-not $Script:BackupPath -or -not (Test-Path -LiteralPath $Script:BackupPath)) { return $false }
        try {
            Stop-Service -Name 'HealthService' -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
            if (Test-Path -LiteralPath $StateDir) {
                Remove-Item -LiteralPath $StateDir -Recurse -Force -ErrorAction SilentlyContinue
            }
            Rename-Item -LiteralPath $Script:BackupPath -NewName 'Health Service State' -ErrorAction Stop
            & sc.exe start HealthService | Out-Null
            Write-Log 'Restored the original Health Service State folder.' -Level 'WARN'
            return $true
        }
        catch {
            Write-Log "Restore failed: $($_.Exception.Message)" -Level 'ERROR'
            return $false
        }
    }

    # -- Execution Engine --
    $activeSteps = $Steps |
        Where-Object { -not $_.ContainsKey('Enabled') -or $_.Enabled }

    $results = [System.Collections.Generic.List[PSCustomObject]]::new()

    Write-Host "`n-- SCOMHealthServiceCacheResolutionWizard ------------------------" -ForegroundColor Cyan
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
        $overall = if ($Script:Restored)      { 'RolledBack' }
                   elseif ($failed -gt 0)     { 'Failed' }
                   elseif ($Script:Flushed)   { 'Completed' }
                   elseif ($Script:BlockReason) { "Skipped:$($Script:BlockReason)" }
                   else                       { 'Completed' }

        Set-ItemProperty -Path $RegPath -Name 'Status'          -Value $overall                    -Type String -ErrorAction Stop -WhatIf:$false
        Set-ItemProperty -Path $RegPath -Name 'LastRunTime'     -Value (Get-Date -Format 'o')      -Type String -ErrorAction Stop -WhatIf:$false
        Set-ItemProperty -Path $RegPath -Name 'ScriptVersion'   -Value $SCRIPT_VERSION             -Type String -ErrorAction Stop -WhatIf:$false
        Set-ItemProperty -Path $RegPath -Name 'Flushed'         -Value ([int]$Script:Flushed)      -Type DWord  -ErrorAction Stop -WhatIf:$false
        Set-ItemProperty -Path $RegPath -Name 'RolledBack'      -Value ([int]$Script:Restored)     -Type DWord  -ErrorAction Stop -WhatIf:$false
        Set-ItemProperty -Path $RegPath -Name 'ReclaimedMB'     -Value ([string]$Script:ReclaimedMB) -Type String -ErrorAction Stop -WhatIf:$false
        Set-ItemProperty -Path $RegPath -Name 'StateFolderMB'   -Value ([string]$Script:StateFolderMB) -Type String -ErrorAction Stop -WhatIf:$false
        Set-ItemProperty -Path $RegPath -Name 'BlockReason'     -Value $Script:BlockReason         -Type String -ErrorAction Stop -WhatIf:$false
        Set-ItemProperty -Path $RegPath -Name 'Passed'          -Value ([string]$passed)           -Type String -ErrorAction Stop -WhatIf:$false
        Set-ItemProperty -Path $RegPath -Name 'Warnings'        -Value ([string]$warnings)         -Type String -ErrorAction Stop -WhatIf:$false
        Set-ItemProperty -Path $RegPath -Name 'Failed'          -Value ([string]$failed)           -Type String -ErrorAction Stop -WhatIf:$false
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
    # Self-cleanup, only from the instance that held the lock.
    # Unregistering from a lock-loser would kill the winner's task.
    if ($owned) {
        if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        }
        $mutex.ReleaseMutex()
    }
    if ($mutex) { $mutex.Dispose() }
}
