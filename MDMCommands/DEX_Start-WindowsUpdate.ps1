<#
.SYNOPSIS
    Turns Windows Update back ON and makes the device update now.

.DESCRIPTION
    The "on" half of the DEX Windows Update on/off pair. Re-enables and starts
    the Windows Update service, clears any Pause, and then forces an update
    cycle in one of three ways chosen by $InstallMode:

      Orchestrator (default)  Asks the Update Orchestrator (UsoClient.exe) to
                              scan, download and install now. The device's own
                              update policy decides the source (WSUS, Windows
                              Update for Business, Windows Update), the
                              deferrals, and when it may restart. Returns in
                              seconds; the work continues under UsoSvc.
      Direct                  Dispatches a scheduled task that uses the Windows
                              Update Agent API to search, download and install
                              every applicable update itself, without waiting
                              on the orchestrator's schedule or on the user.
                              Use it when Orchestrator mode downloads but does
                              not install (a "notify before install" policy,
                              AUOptions 2 or 3) or when the orchestrator is
                              wedged. Takes minutes to hours; progress is in
                              the log and the registry stamp.
      None                    Turn the service on and clear the pause only.

    Neither mode restarts the device. Restarts stay with the update policy
    (active hours, deadlines) or with the scripts in WindowsReboot\.

    Where it reports:
      Console output        state before and after, and what was triggered
      Registry              HKLM:\Software\AirWatch\Extensions\WindowsUpdateControl
                            Mode, Status, LastRun, LastResult; in Direct mode also
                            Found, Installed, Failed and RebootRequired
      Log (Direct mode)     %SystemRoot%\Temp\UEM_DEX_Start-WindowsUpdate.log

    Direct mode stages a copy of this script under
    C:\ProgramData\AirWatch\Extensions\WindowsUpdateControl and registers the
    scheduled task WS1_DEX_WindowsUpdateInstall. Add an AV/EDR exclusion for
    that folder first; without it the payload can be quarantined and the task
    will appear to succeed while doing nothing.

.PARAMETER Mode
    Command-line override of $InstallMode for console and image-build use:
    Orchestrator, Direct or None. UEM leaves it unset and the tunable applies.

.PARAMETER Wait
    Direct mode only. Runs the install inline and waits for it instead of
    dispatching a scheduled task, so a build pipeline (Packer, MDT, SCCM task
    sequence, Autopilot pre-provisioning) gets progress on the console and a
    meaningful exit code: 0 done, 3010 done and a reboot is required, 1 failed.
    Never use it from UEM; it runs for minutes to hours.

.PARAMETER RunAsPayload
    Internal. Set by the scheduled task that Direct mode registers, and by -Wait.
    Do not pass it from UEM.

.EXAMPLE
    # Golden image patch round, synchronous. Repeat after each reboot until exit 0.
    powershell.exe -ExecutionPolicy Bypass -File .\DEX_Start-WindowsUpdate.ps1 -Mode Direct -Wait

.EXAMPLE
    # Undo the OFF script and leave Windows Update in its default state, nothing triggered.
    powershell.exe -ExecutionPolicy Bypass -File .\DEX_Start-WindowsUpdate.ps1 -Mode None

.NOTES
    Script Name  : DEX_Start-WindowsUpdate.ps1
    Version      : 1.0.1
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-10-29
    Timeout      : 60 seconds (worst case about 35 s: service start poll plus three UsoClient calls)
    WhatIf       : set the WhatIf script variable to true for a dry run
    Pair         : DEX_Stop-WindowsUpdate.ps1 turns updates off again
    Guide        : MDMCommands\WindowsUpdate-OnOff-Guide.md

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Orchestrator', 'Direct', 'None')]
    [string]$Mode,
    [switch]$Wait,
    [switch]$RunAsPayload
)

$SCRIPT_VERSION = '1.0.1'

# -- Tunables ------------------------------------------------------------------
$InstallMode         = 'Orchestrator'   # 'Orchestrator' | 'Direct' | 'None'. UEM: edit here. Console: -Mode overrides.
$ResumePause         = $true            # clear a Pause set by DEX_Stop-WindowsUpdate.ps1 or by a user in Settings
$IncludeDrivers      = $false           # Direct mode: also install driver updates the update source offers
$StartTimeoutSeconds = 15               # how long to wait for wuauserv to reach Running
$UsoWaitSeconds      = 5                # wait on each UsoClient call before moving on; the orchestrator keeps working on its own
$DirectTimeLimitHrs  = 3                # Direct mode: scheduled task hard cap
$DirectDeadlineMin   = 150              # Direct mode: payload will not start a new phase (download/install) after this

if ($Mode) { $InstallMode = $Mode }     # command-line override for console and image-build use

# -- Fixed paths ---------------------------------------------------------------
$RegPath     = 'HKLM:\Software\AirWatch\Extensions\WindowsUpdateControl'
$UxPath      = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
$BaseDir     = 'C:\ProgramData\AirWatch\Extensions\WindowsUpdateControl'
$PayloadPs1  = Join-Path $BaseDir 'DEX_Start-WindowsUpdate.ps1'
$TaskName    = 'WS1_DEX_WindowsUpdateInstall'
$MutexName   = 'Global\WS1_DEX_WindowsUpdateInstall'
$LogPath     = "$env:SystemRoot\Temp\UEM_DEX_Start-WindowsUpdate.log"
$PauseValues = @('PauseUpdatesStartTime', 'PauseUpdatesExpiryTime',
                 'PauseFeatureUpdatesStartTime', 'PauseFeatureUpdatesEndTime',
                 'PauseQualityUpdatesStartTime', 'PauseQualityUpdatesEndTime')

# -- WhatIf bridge -------------------------------------------------------------
# UEM cannot pass -WhatIf. Bridge it from the WhatIf script variable. Absent,
# empty or unparseable means a live run. The payload never runs in WhatIf
# because a dry run never dispatches it.
$WhatIfPreference = $false
if ($env:WhatIf -and -not $RunAsPayload) {
    try   { $WhatIfPreference = [System.Convert]::ToBoolean($env:WhatIf) }
    catch { $WhatIfPreference = $false }
}

# -- Run header ----------------------------------------------------------------
$RunEventId = ([Random]::new()).Next(1000, 9999)
Write-Output "[$RunEventId] Executing DEX_Start-WindowsUpdate, $SCRIPT_VERSION. Started @ '$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))'  WhatIf=$WhatIfPreference  Mode=$InstallMode"
$HEAD = "`r`n[$RunEventId]"

# -- Helpers -------------------------------------------------------------------
function Write-Log {
    # Direct-mode payload only. Under the scheduled task nothing captures stdout, so the
    # log file is the record. Under -Wait the same lines also reach the console.
    param([string]$Message, [string]$Level = 'INFO')
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    "[$timestamp] [$RunEventId] [$Level] $Message" | Out-File -FilePath $LogPath -Append -Encoding UTF8 -ErrorAction SilentlyContinue
    Write-Output "$HEAD [$Level] $Message"
}

function Get-WindowsUpdateState {
    # Read-only. Every read is wrapped so a missing key or a denied COM call
    # degrades to 'unknown' instead of failing the run.
    $svc = Get-Service -Name wuauserv -ErrorAction SilentlyContinue
    $uso = Get-Service -Name UsoSvc   -ErrorAction SilentlyContinue

    $pol = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'       -ErrorAction SilentlyContinue
    $au  = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'    -ErrorAction SilentlyContinue
    $mdm = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update'  -ErrorAction SilentlyContinue
    $deferValues = @()
    if ($pol) { $deferValues = @($pol.PSObject.Properties | Where-Object { $_.Name -like 'Defer*' -or $_.Name -eq 'BranchReadinessLevel' }) }
    $source = 'Windows Update (no update policy found)'
    if     ($pol.WUServer -and $au.UseWUServer -eq 1) { $source = "WSUS ($($pol.WUServer))" }
    elseif ($deferValues.Count -gt 0)                 { $source = 'Windows Update for Business (deferral policy present)' }
    elseif ($mdm)                                     { $source = 'Windows Update (MDM Update policy present)' }

    $policyPaused = [bool]($pol.PauseQualityUpdatesStartTime -or $pol.PauseFeatureUpdatesStartTime)
    $ux = Get-ItemProperty -Path $UxPath -ErrorAction SilentlyContinue
    $pausedUntil = $null
    foreach ($name in 'PauseUpdatesExpiryTime', 'PauseQualityUpdatesEndTime', 'PauseFeatureUpdatesEndTime') {
        $raw = $ux.$name
        if (-not $raw) { continue }
        $parsed = [datetime]::MinValue
        $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
        if ([datetime]::TryParse([string]$raw, [cultureinfo]::InvariantCulture, $styles, [ref]$parsed)) {
            if ($parsed -gt (Get-Date).ToUniversalTime() -and ((-not $pausedUntil) -or $parsed -gt $pausedUntil)) { $pausedUntil = $parsed }
        }
    }

    $pendingReboot = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
                     (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
                     [bool](Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue)

    $installing = $null
    try { $installing = [bool](New-Object -ComObject 'Microsoft.Update.Installer' -ErrorAction Stop).IsBusy } catch { }

    return [pscustomobject]@{
        ServiceStatus              = if ($svc) { [string]$svc.Status }    else { 'NotFound' }
        ServiceStartType           = if ($svc) { [string]$svc.StartType } else { 'NotFound' }
        OrchestratorStatus         = if ($uso) { [string]$uso.Status }    else { 'NotFound' }
        PolicySource               = $source
        AutoUpdateDisabledByPolicy = ($au.NoAutoUpdate -eq 1)
        AUOptions                  = $au.AUOptions
        PausedByPolicy             = $policyPaused
        PausedUntil                = $pausedUntil      # UTC; $null when not paused
        PendingReboot              = $pendingReboot
        Installing                 = $installing       # $null when it could not be determined
    }
}

function Write-StateReport {
    param($State, [string]$Label)
    $pause = if ($State.PausedUntil) { "paused until $($State.PausedUntil.ToString('yyyy-MM-dd HH:mm')) UTC" } else { 'not paused' }
    if ($State.PausedByPolicy) { $pause += ' (plus a policy pause)' }
    $inst = switch ($State.Installing) { $true { 'yes' } $false { 'no' } default { 'unknown' } }
    Write-Output "$HEAD [$Label] wuauserv: $($State.ServiceStatus) / $($State.ServiceStartType)   UsoSvc: $($State.OrchestratorStatus)"
    Write-Output "$HEAD [$Label] Source: $($State.PolicySource)   AutoUpdate disabled by policy: $($State.AutoUpdateDisabledByPolicy)   AUOptions: $($State.AUOptions)"
    Write-Output "$HEAD [$Label] Pause: $pause   Pending reboot: $($State.PendingReboot)   Installing now: $inst"
}

function Set-ControlStamp {
    # Reporting only. Skipped in a dry run so WhatIf changes nothing on the device.
    param([hashtable]$Values)
    if ($WhatIfPreference) { return }
    try {
        if (-not (Test-Path $RegPath)) { New-Item -Path $RegPath -Force -ErrorAction Stop | Out-Null }
        Set-ItemProperty -Path $RegPath -Name 'Mode'          -Value 'On'                  -Type String
        Set-ItemProperty -Path $RegPath -Name 'LastRun'       -Value (Get-Date -Format 'o') -Type String
        Set-ItemProperty -Path $RegPath -Name 'ScriptVersion' -Value $SCRIPT_VERSION       -Type String
        foreach ($k in $Values.Keys) { Set-ItemProperty -Path $RegPath -Name $k -Value ([string]$Values[$k]) -Type String }
    } catch {
        if ($RunAsPayload) { Write-Log "Could not write the status stamp: $($_.Exception.Message)" -Level 'WARN' }
        else               { Write-Output "$HEAD Could not write the status stamp: $($_.Exception.Message)" }
    }
}

function Invoke-UsoClient {
    # Runs one UsoClient verb detached from this process's stdio handles so Hub
    # does not wait on a child that outlives the script. Returns a one-line result.
    param([string]$Verb)
    $exe = "$env:SystemRoot\System32\UsoClient.exe"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName        = $exe
    $psi.Arguments       = $Verb
    $psi.UseShellExecute = $true
    $psi.WindowStyle     = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $proc = [System.Diagnostics.Process]::Start($psi)
    if ($proc.WaitForExit($UsoWaitSeconds * 1000)) {
        return "UsoClient $Verb returned $($proc.ExitCode)"
    }
    return "UsoClient $Verb is still running after $UsoWaitSeconds s; the orchestrator continues on its own"
}

# ==============================================================================
# Direct-mode payload. Runs inside the scheduled task as SYSTEM, never from UEM.
# ==============================================================================
if ($RunAsPayload) {
    $mutex = $null
    $owned = $false
    try {
        # Layer 2 concurrency lock. Kernel-managed, so it is released however this process ends.
        $mutex = New-Object System.Threading.Mutex($false, $MutexName)
        try   { $owned = $mutex.WaitOne(0) }
        catch [System.Threading.AbandonedMutexException] { $owned = $true; Write-Log 'Acquired abandoned mutex; the previous run did not finish cleanly.' -Level 'WARN' }
        if (-not $owned) { Write-Log 'Another Direct-mode install is already running. Exiting.'; exit 0 }

        $deadline = (Get-Date).AddMinutes($DirectDeadlineMin)
        Write-Log "Payload started, $SCRIPT_VERSION. Deadline for starting new phases: $($deadline.ToString('HH:mm:ss'))"
        Set-ControlStamp @{ Status = 'Running'; LastResult = 'Direct install: searching' }

        $session = New-Object -ComObject 'Microsoft.Update.Session'
        $session.ClientApplicationID = 'DEX_Start-WindowsUpdate'
        $searcher = $session.CreateUpdateSearcher()
        # ServerSelection is left at its default so the search goes wherever the
        # device's policy points: WSUS, Windows Update for Business, or Windows Update.
        $criteria = 'IsInstalled=0 and IsHidden=0'
        if (-not $IncludeDrivers) { $criteria += " and Type='Software'" }
        Write-Log "Searching: $criteria"
        $search = $searcher.Search($criteria)
        $found  = $search.Updates.Count
        Write-Log "Search finished. ResultCode=$($search.ResultCode)  Applicable updates: $found"

        if ($found -eq 0) {
            Set-ControlStamp @{ Status = 'Completed'; LastResult = 'Direct install: nothing applicable'; Found = 0; Installed = 0; Failed = 0; RebootRequired = $false }
            Write-Log 'Nothing to install.'
            exit 0
        }

        $queued = New-Object -ComObject 'Microsoft.Update.UpdateColl'
        foreach ($u in $search.Updates) {
            if ($u.InstallationBehavior.CanRequestUserInput) {
                Write-Log "Skipped (needs user input): $($u.Title)" -Level 'WARN'
                continue
            }
            if (-not $u.EulaAccepted) { try { $u.AcceptEula() } catch { Write-Log "Could not accept EULA for $($u.Title)" -Level 'WARN' } }
            [void]$queued.Add($u)
            Write-Log "Queued: $($u.Title) ($([math]::Round($u.MaxDownloadSize / 1MB)) MB, downloaded=$($u.IsDownloaded))"
        }

        # Download whatever is not already in the cache.
        $toDownload = New-Object -ComObject 'Microsoft.Update.UpdateColl'
        foreach ($u in $queued) { if (-not $u.IsDownloaded) { [void]$toDownload.Add($u) } }
        if ($toDownload.Count -gt 0) {
            if ((Get-Date) -gt $deadline) { Write-Log 'Deadline passed before download. Aborting.' -Level 'ERROR'; Set-ControlStamp @{ Status = 'TimedOut'; LastResult = 'Direct install: deadline before download' }; exit 1 }
            Set-ControlStamp @{ Status = 'Running'; LastResult = "Direct install: downloading $($toDownload.Count) update(s)"; Found = $found }
            Write-Log "Downloading $($toDownload.Count) update(s)."
            $downloader = $session.CreateUpdateDownloader()
            $downloader.Updates = $toDownload
            $dl = $downloader.Download()
            Write-Log "Download finished. ResultCode=$($dl.ResultCode) (2=ok, 3=partial, 4=failed)"
        }

        $ready = New-Object -ComObject 'Microsoft.Update.UpdateColl'
        foreach ($u in $queued) { if ($u.IsDownloaded) { [void]$ready.Add($u) } }
        if ($ready.Count -eq 0) {
            Write-Log 'No update finished downloading; nothing to install.' -Level 'ERROR'
            Set-ControlStamp @{ Status = 'Failed'; LastResult = 'Direct install: downloads failed'; Found = $found; Installed = 0; Failed = $queued.Count }
            exit 1
        }
        if ((Get-Date) -gt $deadline) { Write-Log 'Deadline passed before install. Aborting; downloads are cached for next time.' -Level 'ERROR'; Set-ControlStamp @{ Status = 'TimedOut'; LastResult = 'Direct install: deadline before install' }; exit 1 }

        # Install. This call is synchronous; the task's ExecutionTimeLimit is the hard cap.
        Set-ControlStamp @{ Status = 'Running'; LastResult = "Direct install: installing $($ready.Count) update(s)"; Found = $found }
        Write-Log "Installing $($ready.Count) update(s)."
        $installer = $session.CreateUpdateInstaller()
        $installer.Updates    = $ready
        $installer.ForceQuiet = $true
        $inst = $installer.Install()

        $installed = 0
        $failed    = 0
        for ($i = 0; $i -lt $ready.Count; $i++) {
            $r = $inst.GetUpdateResult($i)
            if ($r.ResultCode -eq 2 -or $r.ResultCode -eq 3) {
                $installed++
                Write-Log "Installed: $($ready.Item($i).Title) (ResultCode=$($r.ResultCode))"
            } else {
                $failed++
                Write-Log "FAILED: $($ready.Item($i).Title) ResultCode=$($r.ResultCode) HResult=0x$('{0:X8}' -f $r.HResult)" -Level 'ERROR'
            }
        }
        $status = if ($failed -eq 0) { 'Completed' } elseif ($installed -gt 0) { 'CompletedWithErrors' } else { 'Failed' }
        $summary = "Direct install: $installed installed, $failed failed of $($ready.Count); reboot required=$($inst.RebootRequired)"
        Write-Log "$summary (overall ResultCode=$($inst.ResultCode))"
        Set-ControlStamp @{ Status = $status; LastResult = $summary; Found = $found; Installed = $installed; Failed = $failed; RebootRequired = $inst.RebootRequired }

        # Clean up the task that launched this run. The process keeps running after unregistering.
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        if ($status -eq 'Failed')  { exit 1 }
        if ($inst.RebootRequired)  { exit 3010 }
        exit 0
    }
    catch {
        Write-Log "ERROR: $($_.Exception.Message)" -Level 'ERROR'
        Set-ControlStamp @{ Status = 'Failed'; LastResult = "Direct install: $($_.Exception.Message)" }
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        exit 1
    }
    finally {
        if ($owned) { $mutex.ReleaseMutex() }
        if ($mutex) { $mutex.Dispose() }
    }
}

# ==============================================================================
# Main. Runs synchronously under Hub.
# ==============================================================================
try {
    if ($InstallMode -notin 'Orchestrator', 'Direct', 'None') {
        Write-Output "$HEAD `$InstallMode is '$InstallMode'. Expected Orchestrator, Direct or None."
        exit 1
    }

    $before = Get-WindowsUpdateState
    Write-StateReport -State $before -Label 'Before'

    if ($before.ServiceStatus -eq 'NotFound') {
        Write-Output "$HEAD The Windows Update service (wuauserv) was not found. Nothing to do."
        exit 1
    }

    # 1. Start type. Manual is the Windows default on Windows 10 and 11.
    if ($before.ServiceStartType -eq 'Disabled') {
        if ($PSCmdlet.ShouldProcess('wuauserv', 'Set start type to Manual')) {
            Set-Service -Name wuauserv -StartupType Manual -ErrorAction Stop
            Write-Output "$HEAD wuauserv start type set to Manual."
        }
    } else {
        Write-Output "$HEAD wuauserv start type is $($before.ServiceStartType); left as is."
    }

    # 2. Start. sc.exe returns at START_PENDING; poll instead of letting Start-Service block for the full SCM timeout.
    if ($before.ServiceStatus -ne 'Running') {
        if ($PSCmdlet.ShouldProcess('wuauserv', 'Start service')) {
            & sc.exe start wuauserv | Out-Null
            $deadline = (Get-Date).AddSeconds($StartTimeoutSeconds)
            do {
                Start-Sleep -Milliseconds 500
                $status = (Get-Service -Name wuauserv -ErrorAction SilentlyContinue).Status
            } while ($status -ne 'Running' -and (Get-Date) -lt $deadline)
            if ($status -ne 'Running') {
                Write-Output "$HEAD wuauserv did not reach Running within $StartTimeoutSeconds s (status: $status). Not triggering an update cycle."
                Set-ControlStamp @{ Status = 'Failed'; LastResult = "wuauserv did not start (status $status)" }
                exit 1
            }
            Write-Output "$HEAD wuauserv started."
        }
    } else {
        Write-Output "$HEAD wuauserv is already running."
    }

    # 3. Resume. Clears the six Settings-app pause values and tells the orchestrator to resume.
    $hasUso = Test-Path "$env:SystemRoot\System32\UsoClient.exe"
    if ($ResumePause) {
        if ($before.PausedUntil) {
            if ($PSCmdlet.ShouldProcess('Windows Update', 'Clear the pause')) {
                foreach ($name in $PauseValues) { Remove-ItemProperty -Path $UxPath -Name $name -ErrorAction SilentlyContinue }
                if ($hasUso) { Write-Output "$HEAD $(Invoke-UsoClient 'ResumeUpdate')" }
                Write-Output "$HEAD Pause cleared."
            }
        } else {
            Write-Output "$HEAD No pause to clear."
        }
        if ($before.PausedByPolicy) {
            Write-Output "$HEAD WARNING: a policy pause is set (WS1 profile or GPO). This script does not override policy; installs stay paused until that policy changes."
        }
    }

    # 4. Trigger the update cycle.
    switch ($InstallMode) {

        'None' {
            Set-ControlStamp @{ Status = 'Completed'; LastResult = 'Service enabled; no install triggered' }
            Write-Output "$HEAD Windows Update is ON. No install was triggered (`$InstallMode = None)."
        }

        'Orchestrator' {
            if ($before.AutoUpdateDisabledByPolicy) {
                Write-Output "$HEAD WARNING: policy sets NoAutoUpdate=1. The orchestrator will scan but will not install on its own. Use Direct mode to force the install."
            } elseif ($before.AUOptions -in 2, 3) {
                Write-Output "$HEAD WARNING: policy AUOptions=$($before.AUOptions) means notify before download/install. The orchestrator will stop and wait for the user. Use Direct mode to force the install."
            }
            if ($PSCmdlet.ShouldProcess('Update Orchestrator', 'Scan, download and install now')) {
                if ($hasUso) {
                    Write-Output "$HEAD $(Invoke-UsoClient 'RefreshSettings')"
                    Write-Output "$HEAD $(Invoke-UsoClient 'ScanInstallWait')"
                    $result = 'Orchestrator cycle requested (RefreshSettings, ScanInstallWait)'
                } else {
                    # Pre-Windows 10 1607: no orchestrator, the legacy agent takes these.
                    & "$env:SystemRoot\System32\wuauclt.exe" /resetauthorization /detectnow 2>$null
                    & "$env:SystemRoot\System32\wuauclt.exe" /updatenow 2>$null
                    $result = 'Legacy agent cycle requested (wuauclt /detectnow /updatenow)'
                }
                Set-ControlStamp @{ Status = 'Triggered'; LastResult = $result }
                Write-Output "$HEAD Windows Update is ON and a scan/download/install cycle has been requested. Allow 5 to 30 minutes; the device's policy governs any restart."
            }
        }

        'Direct' {
            # Layer 1 concurrency gate: do not stack a second task on a running one.
            $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
            if ($existing -and $existing.State -eq 'Running') {
                Write-Output "$HEAD A Direct-mode install is already running (task $TaskName). Not dispatching another."
                exit 0
            }
            if ($Wait) {
                # Console and image-build use: run the payload inline and wait for it. Progress
                # goes to the console and the log; the exit code is the payload's.
                if ($PSCmdlet.ShouldProcess('Windows Update Agent', 'Search, download and install now, inline')) {
                    Set-ControlStamp @{ Status = 'Dispatched'; LastResult = 'Direct install running inline (-Wait)' }
                    Write-Output "$HEAD Running the Direct install inline. This takes minutes to hours."
                    # Under Hub (stdin) there is no file to re-run, so stage the running text first.
                    $selfFile = $PSCommandPath
                    if ([string]::IsNullOrEmpty($selfFile)) {
                        if (-not (Test-Path $BaseDir)) { New-Item -ItemType Directory -Path $BaseDir -Force -ErrorAction Stop | Out-Null }
                        Set-Content -LiteralPath $PayloadPs1 -Value $MyInvocation.MyCommand.ScriptBlock.ToString() -Encoding UTF8 -Force -ErrorAction Stop
                        $selfFile = $PayloadPs1
                    }
                    & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $selfFile -RunAsPayload
                    $code = $LASTEXITCODE
                    Write-Output "$HEAD Direct install finished with exit code $code (0 done, 3010 done and reboot required, 1 failed)."
                    exit $code
                }
                exit 0
            }
            if ($PSCmdlet.ShouldProcess($TaskName, 'Register and start the Direct install task')) {
                if (-not (Test-Path $BaseDir)) { New-Item -ItemType Directory -Path $BaseDir -Force -ErrorAction Stop | Out-Null }
                # Self-copy: UEM deletes its temp copy of this script as soon as it exits.
                # Hub runs scripts via stdin (no $PSCommandPath to copy), so write the running text itself.
                Set-Content -LiteralPath $PayloadPs1 -Value $MyInvocation.MyCommand.ScriptBlock.ToString() -Encoding UTF8 -Force -ErrorAction Stop
                if ($existing) { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue }

                $psExe     = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
                $action    = New-ScheduledTaskAction -Execute $psExe `
                                -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PayloadPs1`" -RunAsPayload"
                $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
                $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours $DirectTimeLimitHrs) `
                                -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Hidden
                Register-ScheduledTask -TaskName $TaskName -Action $action -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
                Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop

                Set-ControlStamp @{ Status = 'Dispatched'; LastResult = "Direct install task '$TaskName' started" }
                Write-Output "$HEAD Windows Update is ON and the Direct install task '$TaskName' is running as SYSTEM."
                Write-Output "$HEAD Progress: $LogPath and the Status value under $RegPath. Hard cap $DirectTimeLimitHrs h."
            }
        }
    }

    if (-not $WhatIfPreference) {
        $after = Get-WindowsUpdateState
        Write-StateReport -State $after -Label 'After'
    }
    exit 0
}
catch {
    Write-Error "$HEAD ERROR: $($_.Exception.Message)"
    Set-ControlStamp @{ Status = 'Failed'; LastResult = $_.Exception.Message }
    exit 1
}
