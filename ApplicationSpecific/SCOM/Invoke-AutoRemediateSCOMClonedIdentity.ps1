#Requires -Version 5.1
<#
.SYNOPSIS
    SCOMClonedIdentityResolutionWizard -- Re-register an agent whose identity came from a golden image. DESTRUCTIVE.

.DESCRIPTION
    Split out of Invoke-AutoRemediateSCOMAgent.ps1 deliberately. Deploying THIS script
    is the opt-in -- do not fold it back into a general health sweep. It has the
    highest blast radius of the three SCOM spin-offs.

    Six steps: 1 Admin Confirmation Gate, 2 Agent and Install Guard, 3 Image-Baked
    State Detection, 4 Rejection Evidence Confirmation, 5 Identity Reset, 6 Post-Reset
    Verification. Steps 1-4 are all abort gates and ALL must pass.

    An agent's identity lives in its Health Service State folder, not in its registry
    configuration -- so every machine cloned from an image captured with the agent
    already started inherits one identity, and the management group accepts one and
    rejects the rest. Steps 3 and 4 must BOTH find their signal, because a device-side
    script cannot see that another device shares its identity; it can only observe
    that this agent is rejected AND that its state predates this machine. Either
    signal alone aborts.

    The state folder is RENAMED, not deleted, and restored automatically if the agent
    does not come back. Deletion happens only after step 6 confirms recovery. A
    cooldown marker prevents a device churning the management group with repeat
    registrations.

    The management server may still hold a stale record for the old identity. Where
    the management group does not auto-approve, an administrator must approve the new
    registration or delete the stale one -- step 6 says so rather than reporting a
    success the console will not agree with.

    >> Full rationale -- the golden-image failure mode, why the correct fix is upstream
       in the image, why this is the WRONG TOOL for non-persistent VDI, and rollout
       guidance -- is in ApplicationSpecific/SCOM/README.md sections 6.3 and 7. Read
       both before deploying.

.NOTES
    Script Name  : Invoke-AutoRemediateSCOMClonedIdentity.ps1
    Version      : 1.0.0
    Architecture : x64
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-22
    Timeout      : ~5 seconds (launcher exits immediately; payload runs via scheduled task, self-capped at 15 minutes)

    Environment variables:
      ConfirmHighImpact = true   REQUIRED. Absent/unparseable => nothing is reset.
      WhatIf            = true   Dry run. Absent/unparseable => live run.

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
function Invoke-AutoRemediateSCOMClonedIdentity {
[CmdletBinding(SupportsShouldProcess = $true)]
param([switch]$RunAsPayload)

$SCRIPT_VERSION = '1.0.0'

# -- Dispatch constants (shared by launcher and payload) --
$TaskName   = 'WS1_SCOMClonedIdentity'
$MutexName  = 'Global\WS1_DEX_SCOMClonedIdentity'
$BaseDir    = Join-Path $env:ProgramData 'AirWatch\Extensions\SCOM'
$PayloadPs1 = Join-Path $BaseDir 'Invoke-AutoRemediateSCOMClonedIdentity.ps1'
$RegPath    = 'HKLM:\Software\AirWatch\Extensions\SCOM\ClonedIdentity'
$LogPath    = "$env:SystemRoot\Temp\UEM_AutoRemediateSCOMClonedIdentity.log"

$RunEventId = ([Random]::new()).Next(1000, 9999)
$HEAD       = "`r`n[$RunEventId]"

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    "[$timestamp] [$RunEventId] [$Level] $Message" |
        Out-File -FilePath $LogPath -Append -Encoding UTF8 -WhatIf:$false -ErrorAction SilentlyContinue
}

# -- Launcher (UEM dispatcher) --
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
                         -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command `"`$env:RunAsPayload='true'; & '$PayloadPs1'`""
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
# -- Tunables --
# Hard-coded deliberately -- fork the script object per ring. See README section 10.
$RejectionLookbackHours = 24    # Window searched for management server rejection events
$MinRejectionCount      = 3     # Rejections needed before the evidence counts
$StateAgeGraceMinutes   = 30    # State may legitimately predate OS install by this much
$MinIntervalDays        = 14    # Cooldown -- a device may not reset identity more often
$ServiceStopTimeoutS    = 60
$ServiceStartTimeoutS   = 90
$RegistrationWaitSecs   = 300   # How long to wait for the agent to re-register
$RegistrationPollSecs   = 15
$BackupRetentionHours   = 24
$MaxRuntimeMinutes      = 15    # Self-enforced deadline

$Deadline = (Get-Date).AddMinutes($MaxRuntimeMinutes)

# -- WhatIf bridge --
$WhatIfPreference = $false
if ($env:WhatIf) {
    try   { $WhatIfPreference = [System.Convert]::ToBoolean($env:WhatIf) }
    catch { $WhatIfPreference = $false }
}

# -- Admin confirmation gate --
# High-impact action. FAILS CLOSED: absent or unparseable => do not proceed.
$ConfirmHighImpact = $false
if ($env:ConfirmHighImpact) {
    try   { $ConfirmHighImpact = [System.Convert]::ToBoolean($env:ConfirmHighImpact) }
    catch { $ConfirmHighImpact = $false }
}

Write-Output "[$RunEventId] Executing Invoke-AutoRemediateSCOMClonedIdentity payload, $SCRIPT_VERSION. Started @ '$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))'  WhatIf=$WhatIfPreference  ConfirmHighImpact=$ConfirmHighImpact"
Write-Log "Payload started. WhatIf=$WhatIfPreference ConfirmHighImpact=$ConfirmHighImpact"

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

    # Progress marker only -- a run whose key is unwritable should still report.
    try {
        # -ErrorAction Stop on both: a registry PermissionDenied is NON-terminating,
        # so without it the failure sails straight past this catch.
        if (-not (Test-Path $RegPath)) { New-Item -Path $RegPath -Force -ErrorAction Stop -WhatIf:$false | Out-Null }
        Set-ItemProperty -Path $RegPath -Name 'Status' -Value 'Running' -Type String -ErrorAction Stop -WhatIf:$false
    }
    catch {
        Write-Log "Could not write the Running marker to $RegPath -- $($_.Exception.Message)" -Level 'WARN'
    }

    # -- Cooldown gate --
    $last = (Get-ItemProperty -Path $RegPath -Name 'LastResetTime' -ErrorAction SilentlyContinue).LastResetTime
    if ($last) {
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParse($last, [ref]$parsed)) {
            if ((Get-Date) -lt $parsed.AddDays($MinIntervalDays)) {
                Write-Output "$HEAD Identity reset at $parsed, within the ${MinIntervalDays}-day cooldown. Skipping."
                Write-Log "Within cooldown (last reset $parsed). Skipping."
                Set-ItemProperty -Path $RegPath -Name 'Status'      -Value 'SkippedCooldown'      -Type String -ErrorAction Stop -WhatIf:$false
                Set-ItemProperty -Path $RegPath -Name 'LastRunTime' -Value (Get-Date -Format 'o') -Type String -ErrorAction Stop -WhatIf:$false
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

    $StateDir  = if ($installDir) { Join-Path $installDir 'Health Service State' } else { '' }
    $ConfigDir = if ($StateDir)   { Join-Path $StateDir 'Connector Configuration Cache' } else { '' }

    Write-Log "AgentRoot: $agentRoot | InstallDir: $installDir | StateDir: $StateDir"

    # -- Housekeeping: clear leftover backups from earlier runs --
    if ($installDir -and (Test-Path -LiteralPath $installDir)) {
        $stale = @(Get-ChildItem -LiteralPath $installDir -Directory -Filter 'Health Service State.dexid-*' -ErrorAction SilentlyContinue |
                   Where-Object { $_.CreationTime -lt (Get-Date).AddHours(-$BackupRetentionHours) })
        foreach ($s in $stale) {
            Remove-Item -LiteralPath $s.FullName -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "Removed stale backup: $($s.Name)"
        }
    }

    # -- Shared state --
    $Script:AbortReset    = $false
    $Script:BlockReason   = ''
    $Script:BackupPath    = ''
    $Script:Reset         = $false
    $Script:Restored      = $false
    $Script:Rejections    = -1
    $Script:StateAgeDays  = -1
    $Script:ImageBaked    = $false

# Compact result constructor -- see the long-form note in Invoke-AutoRemediateSCOMAgent.ps1.
    function Res { param([string]$S, [string]$M) return @{ Status = $S; Message = $M } }
        # -- Step Definitions --
        # Fields: Name, DetectionScript, and ResolutionScript where the step acts.
        # Optional: Enabled = $false to ship a step disabled. Order is array order.
    $Steps = @(

        @{
            Name             = 'Admin Confirmation Gate'
            DetectionScript  = {
                if (-not $ConfirmHighImpact) {
                    $Script:AbortReset  = $true
                    $Script:BlockReason = 'NotConfirmed'
                    return Res Warning "Not confirmed -- set the ConfirmHighImpact variable to 'true' on the script object to allow an identity reset. Detection results below are reported for review; nothing will be changed."
                }
                return Res Passed 'High-impact action confirmed by the administrator'
            }
        },

        @{
            Name             = 'Agent and Install Guard'
            DetectionScript  = {
                if (-not $agentRoot -or -not $installDir) {
                    $Script:AbortReset  = $true
                    $Script:BlockReason = 'NoAgent'
                    return Res Warning 'No Operations Manager agent installed -- no identity to reset'
                }
                if (-not (Test-Path -LiteralPath $StateDir)) {
                    $Script:AbortReset  = $true
                    $Script:BlockReason = 'NoStateFolder'
                    return Res Warning "Health Service State folder not present at '$StateDir' -- the agent will register fresh on its own; nothing to reset"
                }

                $blockers = @()
                foreach ($p in 'MOMAgentInstaller', 'sysprep', 'TrustedInstaller') {
                    if (Get-Process -Name $p -ErrorAction SilentlyContinue) { $blockers += "$p.exe" }
                }
                if ($blockers.Count -gt 0) {
                    $Script:AbortReset  = $true
                    $Script:BlockReason = 'InstallInProgress'
                    return Res Warning "Aborting -- install, servicing, or image preparation in progress: $($blockers -join ', ')"
                }

                return Res Passed 'Agent present, no install or image preparation in progress'
            }
        },

        @{
            Name             = 'Image-Baked State Detection'
            DetectionScript  = {
                if ($Script:AbortReset) {
                    return Res Passed 'Skipped -- blocked by an earlier gate'
                }

                $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
                if (-not $os -or -not $os.InstallDate) {
                    $Script:AbortReset  = $true
                    $Script:BlockReason = 'InstallDateUnknown'
                    return Res Warning 'Aborting -- OS install date is not readable, so image-baked state cannot be distinguished from legitimate state'
                }

                $stateCreated = (Get-Item -LiteralPath $StateDir -ErrorAction SilentlyContinue).CreationTime
                if (-not $stateCreated) {
                    $Script:AbortReset  = $true
                    $Script:BlockReason = 'StateAgeUnknown'
                    return Res Warning 'Aborting -- Health Service State creation time is not readable'
                }

                $Script:StateAgeDays = [math]::Round(((Get-Date) - $stateCreated).TotalDays, 1)
                $installDate         = $os.InstallDate

                # State predating this OS install arrived in the image, carrying its identity.
                if ($stateCreated -lt $installDate.AddMinutes(-$StateAgeGraceMinutes)) {
                    $Script:ImageBaked = $true
                    return Res Passed "Image-baked state confirmed: Health Service State created $($stateCreated.ToString('yyyy-MM-dd HH:mm')) ($($Script:StateAgeDays) days ago), before this OS was installed on $($installDate.ToString('yyyy-MM-dd HH:mm'))"
                }

                $Script:AbortReset  = $true
                $Script:BlockReason = 'StateIsLocal'
                return Res Passed "Health Service State was created on this machine ($($stateCreated.ToString('yyyy-MM-dd HH:mm')), after OS install on $($installDate.ToString('yyyy-MM-dd HH:mm'))) -- identity is not image-inherited. No action; if the agent is still rejected the record is stale server-side and an admin must clear it."
            }
        },

        @{
            Name             = 'Rejection Evidence Confirmation'
            DetectionScript  = {
                if ($Script:AbortReset) {
                    return Res Passed 'Skipped -- blocked by an earlier gate'
                }

                # Image-baked state alone is not enough -- it only matters when the
                # management server is actively refusing it. See README section 6.3.
                # Own try/catch: a missing Operations Manager log throws terminating.
                $rejections = 0
                try {
                    $events = @(Get-WinEvent -FilterHashtable @{
                        LogName   = 'Operations Manager'
                        StartTime = (Get-Date).AddHours(-$RejectionLookbackHours)
                    } -MaxEvents 2000 -ErrorAction SilentlyContinue)

                    # 21016 = no failover hosts / communication not allowed from this computer
                    #         (the management server is refusing the agent)
                    # 20070/20071 = connected then authentication failed
                    $rejections = @($events | Where-Object { $_.Id -in 21016, 20070, 20071 }).Count
                }
                catch {
                    $Script:AbortReset  = $true
                    $Script:BlockReason = 'EventLogUnavailable'
                    Write-Log "Operations Manager log unavailable: $($_.Exception.Message)" -Level 'WARN'
                    return Res Warning 'Aborting -- the Operations Manager event log is not readable, so rejection evidence cannot be confirmed'
                }

                $Script:Rejections = $rejections

                if ($rejections -lt $MinRejectionCount) {
                    $Script:AbortReset  = $true
                    $Script:BlockReason = 'NoRejectionEvidence'
                    return Res Passed "State is image-baked but the management server is not rejecting this agent ($rejections event(s) in ${RejectionLookbackHours}h, need ${MinRejectionCount}). The inherited identity is not causing harm -- fix the parent image, leave this device alone."
                }

                return Res Passed "Rejection evidence confirmed: $rejections event(s) 21016/20070/20071 in the last ${RejectionLookbackHours}h against image-baked state"
            }
        },

        @{
            Name             = 'Identity Reset'
            DetectionScript  = {
                if ($Script:AbortReset) {
                    return Res Passed "Skipped -- blocked by an earlier gate ($($Script:BlockReason)); agent identity is unchanged"
                }
                return Res Failed "Both signals present (image-baked state $($Script:StateAgeDays) days old, $($Script:Rejections) rejections) -- resetting agent identity"
            }
            ResolutionScript = {
                if ((Get-Date) -gt $Deadline) {
                    Write-Log 'Deadline exceeded before the reset began - aborting.' -Level 'ERROR'
                    Set-ItemProperty -Path $RegPath -Name 'Status' -Value 'TimedOut' -Type String -ErrorAction Stop -WhatIf:$false
                    return
                }

                if (-not $PSCmdlet.ShouldProcess($StateDir, 'Stop HealthService and reset agent identity')) { return }

                $svc = Get-Service -Name 'HealthService' -ErrorAction SilentlyContinue
                if ($svc -and $svc.Status -ne 'Stopped') {
                    Stop-Service -Name 'HealthService' -Force -ErrorAction SilentlyContinue
                    try {
                        $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds($ServiceStopTimeoutS))
                    }
                    catch {
                        Write-Log "HealthService did not stop within ${ServiceStopTimeoutS}s - aborting reset." -Level 'ERROR'
                        $Script:BlockReason = 'ServiceWouldNotStop'
                        & sc.exe start HealthService | Out-Null
                        return
                    }
                }

                # Rename rather than delete. If the agent does not come back, step 6
                # restores this folder and the device is no worse off than before.
                $Script:BackupPath = Join-Path $installDir ("Health Service State.dexid-{0}" -f (Get-Date -Format 'yyyyMMddHHmmss'))
                try {
                    Rename-Item -LiteralPath $StateDir -NewName (Split-Path $Script:BackupPath -Leaf) -ErrorAction Stop
                    $Script:Reset = $true
                    Write-Log "Renamed state folder to '$($Script:BackupPath)'; the inherited identity is now detached."
                }
                catch {
                    Write-Log "Rename failed: $($_.Exception.Message)" -Level 'ERROR'
                    $Script:BackupPath  = ''
                    $Script:BlockReason = 'RenameFailed'
                    & sc.exe start HealthService | Out-Null
                    return
                }

                & sc.exe start HealthService | Out-Null
                Write-Log 'Issued start for HealthService; the agent will register with a new identity.'
            }
        },

        @{
            Name             = 'Post-Reset Verification'
            # Report only -- rollback is handled inline below
            DetectionScript  = {
                if (-not $Script:Reset) {
                    return Res Passed 'No identity reset performed -- nothing to verify'
                }

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
                    return Res Failed "HealthService did not start after the reset -- original state folder $(if ($Script:Restored) { 'restored' } else { 'COULD NOT be restored, escalate immediately' })"
                }

                # Registration succeeded only when configuration comes back down.
                $registered = $false
                $waitUntil  = (Get-Date).AddSeconds($RegistrationWaitSecs)
                while ((Get-Date) -lt $waitUntil -and (Get-Date) -lt $Deadline) {
                    if ($ConfigDir -and (Test-Path -LiteralPath $ConfigDir)) {
                        $cfg = Get-ChildItem -Path $ConfigDir -Filter 'OpsMgrConnector.Config.xml' -Recurse -File -ErrorAction SilentlyContinue |
                               Select-Object -First 1
                        if ($cfg) { $registered = $true; break }
                    }
                    Start-Sleep -Seconds $RegistrationPollSecs
                }

                if (-not $registered) {
                    # NOT rolled back: restoring the inherited identity resumes the rejection loop.                    # A fresh unapproved agent is one console click from working.
                    return Res Failed "Identity reset completed but no configuration received within ${RegistrationWaitSecs}s. The old identity was NOT restored -- that would restore the rejection loop. ADMIN ACTION REQUIRED: approve the pending agent in the Operations console, or delete this computer's stale record. Old state at '$($Script:BackupPath)'."
                }

                Remove-Item -LiteralPath $Script:BackupPath -Recurse -Force -ErrorAction SilentlyContinue
                $backupGone = -not (Test-Path -LiteralPath $Script:BackupPath)
                $note = if ($backupGone) { 'old state removed' } else { "old state left at '$($Script:BackupPath)' for manual removal" }

                return Res Passed "Agent re-registered with a new identity and received configuration; $note. FIX THE SOURCE: recapture the parent image without the agent's Health Service State folder, or every future device repeats this."
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

    Write-Output "`r`n-- SCOMClonedIdentityResolutionWizard ----------------------------"
    Write-Output "   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')   Steps: $($activeSteps.Count)"
    Write-Output '----------------------------------------------------------------'

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
    Write-Output "----------------------------------------------------------------`r`n"

    # -- Persist results for DEX sensors --
    try {
        $overall = if ($Script:Restored)        { 'RolledBack' }
                   elseif ($failed -gt 0)       { 'Failed' }
                   elseif ($Script:Reset)       { 'Reset' }
                   elseif ($Script:BlockReason) { "Skipped:$($Script:BlockReason)" }
                   else                         { 'Completed' }

        Set-ItemProperty -Path $RegPath -Name 'Status'        -Value $overall                        -Type String -ErrorAction Stop -WhatIf:$false
        Set-ItemProperty -Path $RegPath -Name 'LastRunTime'   -Value (Get-Date -Format 'o')          -Type String -ErrorAction Stop -WhatIf:$false
        Set-ItemProperty -Path $RegPath -Name 'ScriptVersion' -Value $SCRIPT_VERSION                 -Type String -ErrorAction Stop -WhatIf:$false
        Set-ItemProperty -Path $RegPath -Name 'ImageBaked'    -Value ([int]$Script:ImageBaked)       -Type DWord  -ErrorAction Stop -WhatIf:$false
        Set-ItemProperty -Path $RegPath -Name 'IdentityReset' -Value ([int]$Script:Reset)            -Type DWord  -ErrorAction Stop -WhatIf:$false
        Set-ItemProperty -Path $RegPath -Name 'RolledBack'    -Value ([int]$Script:Restored)         -Type DWord  -ErrorAction Stop -WhatIf:$false
        Set-ItemProperty -Path $RegPath -Name 'Rejections24h' -Value ([string]$Script:Rejections)    -Type String -ErrorAction Stop -WhatIf:$false
        Set-ItemProperty -Path $RegPath -Name 'StateAgeDays'  -Value ([string]$Script:StateAgeDays)  -Type String -ErrorAction Stop -WhatIf:$false
        Set-ItemProperty -Path $RegPath -Name 'BlockReason'   -Value $Script:BlockReason             -Type String -ErrorAction Stop -WhatIf:$false

        if ($Script:Reset) {
            Set-ItemProperty -Path $RegPath -Name 'LastResetTime' -Value (Get-Date -Format 'o') -Type String -ErrorAction Stop -WhatIf:$false
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
}

# -- entry point ---------------------------------------------------------------
# The param block sits inside the function deliberately. The Workspace ONE script
# engine does not recognise a param block at script scope, and $PSCmdlet is $null
# there, which makes every ShouldProcess call throw. Inputs arrive as environment
# variables and are bound to the function's parameters below.

# Async dispatch flag. The launcher re-runs the staged copy through a scheduled
# task, which now sets this environment variable instead of passing -RunAsPayload,
# because the switch no longer exists at script scope.
$RunAsPayload = $false
if ($env:RunAsPayload) {
    try   { $RunAsPayload = [System.Convert]::ToBoolean($env:RunAsPayload) }
    catch { $RunAsPayload = $false }
}

Invoke-AutoRemediateSCOMClonedIdentity -RunAsPayload:$RunAsPayload
Exit 0
