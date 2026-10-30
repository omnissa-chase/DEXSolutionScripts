<#
.SYNOPSIS
    Turns Windows Update OFF on a managed device: disables and stops the Windows
    Update service and, by default, sets the built-in 35-day Pause.

.DESCRIPTION
    The "off" half of the DEX Windows Update on/off pair. Use it to hold a device
    from scanning, downloading or installing updates until
    DEX_Start-WindowsUpdate.ps1 turns it back on. It does not touch the update
    policy the device already has (WSUS, Windows Update for Business, or a
    Workspace ONE Windows Update profile). That policy is still in force when
    the device is turned back on.

    What it does, in order:
      1. Reports the current state: service, policy source, pause, pending reboot.
      2. Declines to proceed while an update is installing, unless
         $StopEvenIfInstalling is set. Interrupting an install is how devices
         end up with a half-applied servicing stack.
      3. Sets the Windows Update service (wuauserv) start type to Disabled.
      4. Stops wuauserv (sc.exe stop, then polls up to $StopTimeoutSeconds).
      5. Sets the built-in Pause Updates for $PauseDays days, using the same
         registry values the Settings app writes. Windows ships a "Windows
         Update Medic" service (WaaSMedicSvc) that puts wuauserv back to Manual
         within about a day; the pause is what keeps the device from resuming
         installs after that happens.
      6. Stamps the result under HKLM:\Software\AirWatch\Extensions\WindowsUpdateControl.

    What it does not stop:
      - A reboot that is already pending still finishes installing whatever was
        staged before this ran. That work is done by the servicing stack at
        boot, not by wuauserv.
      - Microsoft Store app updates, Defender platform/definition updates
        delivered by Defender itself, and third-party updaters.
      - A pause set by policy (WS1 profile or GPO) is reported, never changed.

.PARAMETER NoPause
    Command-line override: disable and stop the service but do not set the
    35-day Pause. For console and image-build use where the hold is shorter
    than the Update Medic reset cycle. UEM leaves it unset.

.EXAMPLE
    # Hold updates for the duration of an image build without leaving a pause in the image
    powershell.exe -ExecutionPolicy Bypass -File .\DEX_Stop-WindowsUpdate.ps1 -NoPause

.NOTES
    Script Name  : DEX_Stop-WindowsUpdate.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-10-29
    Timeout      : 60 seconds (worst case about 30 s: service stop poll plus state checks)
    WhatIf       : set the WhatIf script variable to true for a dry run
    Pair         : DEX_Start-WindowsUpdate.ps1 reverses everything this script does
    Guide        : MDMCommands\WindowsUpdate-OnOff-Guide.md

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param([switch]$NoPause)

$SCRIPT_VERSION = '1.0.0'

# -- Tunables ------------------------------------------------------------------
$PauseUpdates         = $true   # also set the built-in Pause so the Update Medic service cannot quietly resume installs
if ($NoPause) { $PauseUpdates = $false }   # command-line override for console and image-build use (a build is shorter than Medic's reset cycle)
$PauseDays            = 35      # Windows accepts at most 35 days
$StopEvenIfInstalling = $false  # $true: stop the service even while an update is installing (not recommended)
$StopTimeoutSeconds   = 20      # how long to wait for wuauserv to reach Stopped before moving on

# -- Fixed paths ---------------------------------------------------------------
$RegPath      = 'HKLM:\Software\AirWatch\Extensions\WindowsUpdateControl'
$UxPath       = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
$InstallTask  = 'WS1_DEX_WindowsUpdateInstall'    # Direct-mode task registered by DEX_Start-WindowsUpdate.ps1

# -- WhatIf bridge -------------------------------------------------------------
# UEM cannot pass -WhatIf. Bridge it from the WhatIf script variable. Absent,
# empty or unparseable means a live run.
$WhatIfPreference = $false
if ($env:WhatIf) {
    try   { $WhatIfPreference = [System.Convert]::ToBoolean($env:WhatIf) }
    catch { $WhatIfPreference = $false }
}

# -- Run header ----------------------------------------------------------------
$RunEventId = ([Random]::new()).Next(1000, 9999)
Write-Output "[$RunEventId] Executing DEX_Stop-WindowsUpdate, $SCRIPT_VERSION. Started @ '$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))'  WhatIf=$WhatIfPreference"
$HEAD = "`r`n[$RunEventId]"

# -- Helpers -------------------------------------------------------------------
function Get-WindowsUpdateState {
    # Read-only. Every read is wrapped so a missing key or a denied COM call
    # degrades to 'unknown' instead of failing the run.
    $svc = Get-Service -Name wuauserv -ErrorAction SilentlyContinue
    $uso = Get-Service -Name UsoSvc   -ErrorAction SilentlyContinue

    # Policy source: WSUS, Windows Update for Business, MDM Update CSP, or none
    $pol = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'       -ErrorAction SilentlyContinue
    $au  = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'    -ErrorAction SilentlyContinue
    $mdm = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update'  -ErrorAction SilentlyContinue
    $deferValues = @()
    if ($pol) { $deferValues = @($pol.PSObject.Properties | Where-Object { $_.Name -like 'Defer*' -or $_.Name -eq 'BranchReadinessLevel' }) }
    $source = 'Windows Update (no update policy found)'
    if     ($pol.WUServer -and $au.UseWUServer -eq 1) { $source = "WSUS ($($pol.WUServer))" }
    elseif ($deferValues.Count -gt 0)                 { $source = 'Windows Update for Business (deferral policy present)' }
    elseif ($mdm)                                     { $source = 'Windows Update (MDM Update policy present)' }

    # Pause: a policy pause (WS1 profile / GPO) is separate from the Settings-app pause this script sets
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

    # Pending reboot: the three standard indicators
    $pendingReboot = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
                     (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
                     [bool](Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue)

    # Is an install running right now? Either the Windows Update Agent says so,
    # or the Direct-mode task from the "on" script is still running.
    $installing = $null
    try { $installing = [bool](New-Object -ComObject 'Microsoft.Update.Installer' -ErrorAction Stop).IsBusy } catch { }
    $task = Get-ScheduledTask -TaskName $InstallTask -ErrorAction SilentlyContinue
    if ($task -and $task.State -eq 'Running') { $installing = $true }

    return [pscustomobject]@{
        ServiceStatus              = if ($svc) { [string]$svc.Status }    else { 'NotFound' }
        ServiceStartType           = if ($svc) { [string]$svc.StartType } else { 'NotFound' }
        OrchestratorStatus         = if ($uso) { [string]$uso.Status }    else { 'NotFound' }
        PolicySource               = $source
        AutoUpdateDisabledByPolicy = ($au.NoAutoUpdate -eq 1)
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
    Write-Output "$HEAD [$Label] Source: $($State.PolicySource)   AutoUpdate disabled by policy: $($State.AutoUpdateDisabledByPolicy)"
    Write-Output "$HEAD [$Label] Pause: $pause   Pending reboot: $($State.PendingReboot)   Installing now: $inst"
}

function Set-ControlStamp {
    # Reporting only. Skipped in a dry run so WhatIf changes nothing on the device.
    param([hashtable]$Values)
    if ($WhatIfPreference) { return }
    try {
        if (-not (Test-Path $RegPath)) { New-Item -Path $RegPath -Force -ErrorAction Stop | Out-Null }
        Set-ItemProperty -Path $RegPath -Name 'Mode'          -Value 'Off'                 -Type String
        Set-ItemProperty -Path $RegPath -Name 'LastRun'       -Value (Get-Date -Format 'o') -Type String
        Set-ItemProperty -Path $RegPath -Name 'ScriptVersion' -Value $SCRIPT_VERSION       -Type String
        foreach ($k in $Values.Keys) { Set-ItemProperty -Path $RegPath -Name $k -Value ([string]$Values[$k]) -Type String }
    } catch {
        Write-Output "$HEAD Could not write the status stamp: $($_.Exception.Message)"
    }
}

# -- Main ----------------------------------------------------------------------
try {
    $before = Get-WindowsUpdateState
    Write-StateReport -State $before -Label 'Before'

    if ($before.ServiceStatus -eq 'NotFound') {
        Write-Output "$HEAD The Windows Update service (wuauserv) was not found. Nothing to do."
        exit 1
    }

    if ($before.Installing -eq $true -and -not $StopEvenIfInstalling) {
        Write-Output "$HEAD SKIPPED: an update is installing right now. Stopping the service mid-install can leave the servicing stack half-applied."
        Write-Output "$HEAD Re-run after the install finishes, or set `$StopEvenIfInstalling to `$true in the script to override."
        Set-ControlStamp @{ Status = 'SkippedInstalling'; LastResult = 'Update install in progress; service left running' }
        exit 0
    }

    if ($before.PendingReboot) {
        Write-Output "$HEAD Note: a reboot is already pending. Updates staged before this run will still complete at the next restart."
    }

    # 1. Start type. Disabled is what keeps UsoSvc from starting it again on the next scheduled scan.
    if ($before.ServiceStartType -ne 'Disabled') {
        if ($PSCmdlet.ShouldProcess('wuauserv', 'Set start type to Disabled')) {
            Set-Service -Name wuauserv -StartupType Disabled -ErrorAction Stop
            Write-Output "$HEAD wuauserv start type set to Disabled."
        }
    } else {
        Write-Output "$HEAD wuauserv start type is already Disabled."
    }

    # 2. Stop. sc.exe returns at STOP_PENDING; poll instead of letting Stop-Service block for the full SCM timeout.
    $stopResult = 'already stopped'
    if ($before.ServiceStatus -ne 'Stopped') {
        if ($PSCmdlet.ShouldProcess('wuauserv', 'Stop service')) {
            & sc.exe stop wuauserv | Out-Null
            $deadline = (Get-Date).AddSeconds($StopTimeoutSeconds)
            do {
                Start-Sleep -Milliseconds 500
                $status = (Get-Service -Name wuauserv -ErrorAction SilentlyContinue).Status
            } while ($status -ne 'Stopped' -and (Get-Date) -lt $deadline)
            if ($status -eq 'Stopped') {
                $stopResult = 'stopped'
                Write-Output "$HEAD wuauserv stopped."
            } else {
                $stopResult = "stop pending ($status after $StopTimeoutSeconds s)"
                Write-Output "$HEAD wuauserv is still '$status' after $StopTimeoutSeconds s. The stop completes on its own, and with the start type Disabled it will not come back."
            }
        }
    } else {
        Write-Output "$HEAD wuauserv is already stopped."
    }

    # 3. Pause. Same six values the Settings app writes when a user clicks "Pause updates".
    $pauseUntilText = ''
    if ($PauseUpdates) {
        $start = (Get-Date).ToUniversalTime()
        $end   = $start.AddDays($PauseDays)
        $fmt   = 'yyyy-MM-ddTHH:mm:ssZ'
        $pauseUntilText = $end.ToString('yyyy-MM-dd')
        if ($PSCmdlet.ShouldProcess('Windows Update', "Pause updates until $pauseUntilText (UTC)")) {
            if (-not (Test-Path $UxPath)) { New-Item -Path $UxPath -Force -ErrorAction Stop | Out-Null }
            Set-ItemProperty -Path $UxPath -Name 'PauseUpdatesStartTime'        -Value $start.ToString($fmt) -Type String -ErrorAction Stop
            Set-ItemProperty -Path $UxPath -Name 'PauseUpdatesExpiryTime'       -Value $end.ToString($fmt)   -Type String -ErrorAction Stop
            Set-ItemProperty -Path $UxPath -Name 'PauseFeatureUpdatesStartTime' -Value $start.ToString($fmt) -Type String -ErrorAction Stop
            Set-ItemProperty -Path $UxPath -Name 'PauseFeatureUpdatesEndTime'   -Value $end.ToString($fmt)   -Type String -ErrorAction Stop
            Set-ItemProperty -Path $UxPath -Name 'PauseQualityUpdatesStartTime' -Value $start.ToString($fmt) -Type String -ErrorAction Stop
            Set-ItemProperty -Path $UxPath -Name 'PauseQualityUpdatesEndTime'   -Value $end.ToString($fmt)   -Type String -ErrorAction Stop
            Write-Output "$HEAD Updates paused until $pauseUntilText (UTC). DEX_Start-WindowsUpdate.ps1 clears this."
        }
    } else {
        Write-Output "$HEAD Pause not set (`$PauseUpdates is `$false). Expect the Update Medic service to re-enable wuauserv within about a day."
    }

    Set-ControlStamp @{
        Status     = 'Completed'
        LastResult = "Service Disabled, $stopResult" + $(if ($PauseUpdates) { ", paused until $pauseUntilText" } else { '' })
        PauseUntil = $pauseUntilText
    }

    if (-not $WhatIfPreference) {
        $after = Get-WindowsUpdateState
        Write-StateReport -State $after -Label 'After'
    }
    Write-Output "$HEAD Windows Update is OFF. Run DEX_Start-WindowsUpdate.ps1 to turn it back on and install."
    exit 0
}
catch {
    Write-Error "$HEAD ERROR: $($_.Exception.Message)"
    Set-ControlStamp @{ Status = 'Failed'; LastResult = $_.Exception.Message }
    exit 1
}
