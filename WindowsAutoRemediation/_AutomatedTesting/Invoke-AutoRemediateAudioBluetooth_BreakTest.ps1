<#
.SYNOPSIS
    Invoke-AutoRemediateAudioBluetooth_BreakTest -- deliberately breaks audio and
    Bluetooth components, then verifies Invoke-AutoRemediateAudioBluetooth.ps1
    actually fixes them.

.DESCRIPTION
    Break -> verify-the-break -> remediate -> validate -> restore. Writes a uniform
    JSON result to C:\Temp\FixReport\Invoke-AutoRemediateAudioBluetooth\ for
    Invoke-FixReportAnalysis.ps1 to aggregate.

    EXPECTED OUTCOMES
    Three of the eight steps in Invoke-AutoRemediateAudioBluetooth.ps1 have
    ResolutionScript = $null by design (Default Audio Output Device, Bluetooth
    Device Pairing, Bluetooth Audio Profile) -- all require user interaction and
    are excluded from this catalog rather than forcing an artificial break. The
    five breaks below all target steps with a real ResolutionScript and are all
    ExpectFixed.

    HARDWARE-DEPENDENT BREAKS
      AudioDriverDisabled -- requires a real, healthy audio PnP device. Capture
                             throws a clear error (matching Invoke-AutoRemediatePrinter
                             's Initialize-Fixture / Invoke-AutoRemediateNetworkStack's
                             Get-DhcpAdapter precedent) if none is found -- expected on
                             a bare VM with no virtual audio adapter.
      BluetoothServiceStopped -- only needs the bthserv service, which ships on
                             virtually every Windows image regardless of whether a
                             Bluetooth radio exists. But the target script's own
                             'Passed' status additionally requires a detected adapter,
                             which is unreachable on hardware without one. Validate
                             therefore checks the service's Running state directly
                             rather than the step's overall Status label.

    VOLUME/MUTE CAVEAT (VolumeMuted)
    The target script's detection reads the legacy waveOut mixer API, and its
    remediation sends a VK_VOLUME_MUTE keystroke via WScript.Shell -- two different
    subsystems that may or may not be linked on a given system. This break uses the
    SAME legacy waveOut API the detection reads (not the modern Core Audio session),
    so Verify/Validate stay faithful to what the target script actually measures. If
    the keystroke does not move this same register, Validate will correctly report
    Failed -- a genuine detection/remediation mismatch worth knowing about, not a
    bug in this harness.

    VERIFY-THE-BREAK
    Every break is followed by a probe proving the component is genuinely broken.
    A break that silently no-ops would let the remediation "pass" against a
    healthy machine -- a false green.

.PARAMETER RemediationTest
    After breaking, run Invoke-AutoRemediateAudioBluetooth.ps1 and validate the outcome.
    Without this the script breaks and reports only.

.PARAMETER Environment
    Physical (default) restores the machine when the run ends.
    Snapshot skips restore on the assumption the host reverts a checkpoint.

.PARAMETER Seed
    Replays an earlier run's random break selection exactly. Omit for a new random
    seed, which is always recorded in the result.

.PARAMETER BreakName
    Force specific breaks instead of a random selection.

.PARAMETER BreakCount
    How many components to break when selecting randomly. Default 2.

.PARAMETER Restore
    Undo an in-flight run's breaks and exit. No remediation, no validation.

.PARAMETER Resume
    Internal. Used by the AtStartup task to re-enter after a reboot (unused by this
    catalog today -- none of its breaks require one -- kept for framework symmetry).

.PARAMETER Force
    Required acknowledgement that this machine will be broken.

.NOTES
    Script Name  : Invoke-AutoRemediateAudioBluetooth_BreakTest.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : Administrator (elevated)
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-07
    Reporting    : C:\Temp\FixReport\Invoke-AutoRemediateAudioBluetooth\

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

#Requires -Version 5.1
#Requires -RunAsAdministrator

param(
    [switch]$RemediationTest,
    [ValidateSet('Snapshot', 'Physical')][string]$Environment = 'Physical',
    [int]$Seed = 0,
    [string[]]$BreakName,
    [int]$BreakCount = 2,
    [switch]$Restore,
    [switch]$Resume,
    [switch]$Force,
    [string[]]$ProductionDomainDenyList = @()
)

$ErrorActionPreference = 'Stop'

$ScriptUnderTest   = 'Invoke-AutoRemediateAudioBluetooth'
$RemediationScript = Join-Path $PSScriptRoot '..\Invoke-AutoRemediateAudioBluetooth.ps1'
$SelfPath          = $MyInvocation.MyCommand.Path

$modulePath = Join-Path $PSScriptRoot '..\..\AutomatedTesting\DEXTestFramework.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    throw "DEXTestFramework.psm1 not found at $modulePath"
}
Import-Module $modulePath -Force

# Legacy waveOut mixer API -- the same one the target script's own volume
# detection reads. Loaded once per process; guarded since Add-Type throws if the
# type is already loaded (e.g. -Resume re-entering after a reboot never happens
# here, but repeated dot-sourcing in a test session could).
if (-not ('DexAudioUtils' -as [type])) {
    Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public class DexAudioUtils {
    [DllImport("winmm.dll")] public static extern int waveOutGetVolume(System.IntPtr hwo, out uint dwVolume);
    [DllImport("winmm.dll")] public static extern int waveOutSetVolume(System.IntPtr hwo, uint dwVolume);
}
'@
}

# -- Helpers --------------------------------------------------------------------

function Get-AudioPnpDevice {
    # Deterministic pick so Capture/Verify/Validate resolve to the same device.
    # Same match regex the target script's own Audio Driver Health step uses.
    Get-WmiObject -Class Win32_PnPEntity -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -match 'audio|sound|speaker|headset|realtek|conexant|IDT|Synaptics.*audio|Intel.*Smart Sound' -and
            $_.ConfigManagerErrorCode -eq 0
        } |
        Sort-Object -Property DeviceID |
        Select-Object -First 1
}

function Get-WaveOutVolumePercent {
    $vol  = [uint32]0
    [void][DexAudioUtils]::waveOutGetVolume([System.IntPtr]::Zero, [ref]$vol)
    $left = $vol -band 0xFFFF
    [math]::Round($left / 0xFFFF * 100)
}

function ConvertTo-StartupType {
    param([string]$StartMode)
    switch ($StartMode) {
        'Auto'     { 'Automatic' }
        'Manual'   { 'Manual'    }
        'Disabled' { 'Disabled'  }
        default    { 'Automatic' }
    }
}

# -- Break definitions ------------------------------------------------------------
# Capture runs before any mutation; Restore consumes what it returned.
# Verify proves the break landed. Validate decides whether remediation did its job.
$BreakCatalog = @(

    @{
        Name            = 'AudioServicesStopped'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        Methods         = @(
            @{
                Name  = 'StopBothServices'
                Apply = {
                    Stop-Service -Name AudioSrv             -Force -ErrorAction Stop
                    Stop-Service -Name AudioEndpointBuilder -Force -ErrorAction Stop
                }
            }
        )
        Capture  = {
            $audioSvc = Get-CimInstance -ClassName Win32_Service -Filter "Name='AudioSrv'"             -ErrorAction SilentlyContinue
            $epSvc    = Get-CimInstance -ClassName Win32_Service -Filter "Name='AudioEndpointBuilder'" -ErrorAction SilentlyContinue
            @{
                AudioSrvStartMode = $audioSvc.StartMode; AudioSrvState = $audioSvc.State
                EpSvcStartMode    = $epSvc.StartMode;    EpSvcState    = $epSvc.State
            }
        }
        Verify   = {
            $audioSvc = Get-Service -Name AudioSrv             -ErrorAction SilentlyContinue
            $epSvc    = Get-Service -Name AudioEndpointBuilder -ErrorAction SilentlyContinue
            ($audioSvc.Status -ne 'Running') -or ($epSvc.Status -ne 'Running')
        }
        Validate = {
            $audioSvc = Get-Service -Name AudioSrv             -ErrorAction SilentlyContinue
            $epSvc    = Get-Service -Name AudioEndpointBuilder -ErrorAction SilentlyContinue
            $passed   = ($audioSvc.Status -eq 'Running') -and ($epSvc.Status -eq 'Running')
            @{ Passed = $passed; Detail = "AudioSrv=$($audioSvc.Status) AudioEndpointBuilder=$($epSvc.Status)" }
        }
        Restore  = {
            param($Original)
            Set-Service -Name AudioEndpointBuilder -StartupType (ConvertTo-StartupType $Original.EpSvcStartMode)    -ErrorAction SilentlyContinue
            Set-Service -Name AudioSrv             -StartupType (ConvertTo-StartupType $Original.AudioSrvStartMode) -ErrorAction SilentlyContinue
            # Endpoint builder must start first -- AudioSrv depends on it.
            if ($Original.EpSvcState -eq 'Running')    { Start-Service -Name AudioEndpointBuilder -ErrorAction SilentlyContinue }
            if ($Original.AudioSrvState -eq 'Running') { Start-Service -Name AudioSrv             -ErrorAction SilentlyContinue }
        }
    },

    @{
        Name            = 'AudioDriverDisabled'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        Methods         = @(
            @{
                Name  = 'DisablePnpDevice'
                Apply = {
                    $dev = Get-AudioPnpDevice
                    if (-not $dev) { throw 'No healthy audio PnP device found.' }
                    $script:AudioTargetDeviceId = $dev.DeviceID
                    Disable-PnpDevice -InstanceId $dev.DeviceID -Confirm:$false -ErrorAction Stop
                }
            }
        )
        Capture  = {
            $dev = Get-AudioPnpDevice
            if (-not $dev) { throw 'No healthy audio PnP device found; cannot test AudioDriverDisabled (needs real/virtual audio hardware).' }
            $script:AudioTargetDeviceId = $dev.DeviceID
            @{ DeviceId = $dev.DeviceID }
        }
        Verify   = {
            $dev = Get-WmiObject -Class Win32_PnPEntity -ErrorAction SilentlyContinue |
                   Where-Object { $_.DeviceID -eq $script:AudioTargetDeviceId }
            $dev -and ($dev.ConfigManagerErrorCode -ne 0)
        }
        Validate = {
            $dev     = Get-WmiObject -Class Win32_PnPEntity -ErrorAction SilentlyContinue |
                       Where-Object { $_.DeviceID -eq $script:AudioTargetDeviceId }
            $errCode = if ($dev) { $dev.ConfigManagerErrorCode } else { -1 }
            @{ Passed = ($errCode -eq 0); Detail = "ConfigManagerErrorCode=$errCode" }
        }
        Restore  = {
            param($Original)
            # Safety net regardless of whether the remediation's pnputil restart worked.
            Enable-PnpDevice -InstanceId $Original.DeviceId -Confirm:$false -ErrorAction SilentlyContinue
        }
    },

    @{
        Name            = 'VolumeMuted'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        Methods         = @(
            @{
                Name  = 'WaveOutSetVolumeZero'
                Apply = { [void][DexAudioUtils]::waveOutSetVolume([System.IntPtr]::Zero, 0) }
            }
        )
        Capture  = {
            $vol = [uint32]0
            [void][DexAudioUtils]::waveOutGetVolume([System.IntPtr]::Zero, [ref]$vol)
            @{ RawVolume = $vol }
        }
        Verify   = { (Get-WaveOutVolumePercent) -eq 0 }
        Validate = {
            $pct = Get-WaveOutVolumePercent
            @{ Passed = ($pct -gt 0); Detail = "VolumePct=$pct" }
        }
        Restore  = {
            param($Original)
            [void][DexAudioUtils]::waveOutSetVolume([System.IntPtr]::Zero, [uint32]$Original.RawVolume)
        }
    },

    @{
        Name            = 'MicrophoneAccessDenied'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        Methods         = @(
            @{
                Name  = 'SetConsentStoreDeny'
                Apply = {
                    $micKey = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone'
                    if (-not (Test-Path "$micKey\NonPackaged")) { New-Item -Path "$micKey\NonPackaged" -Force | Out-Null }
                    Set-ItemProperty -Path $micKey               -Name Value -Value 'Deny' -ErrorAction Stop
                    Set-ItemProperty -Path "$micKey\NonPackaged" -Name Value -Value 'Deny' -ErrorAction Stop
                }
            }
        )
        Capture  = {
            $micKey = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone'
            @{
                Value      = (Get-ItemProperty -Path $micKey               -Name Value -ErrorAction SilentlyContinue).Value
                Desktop    = (Get-ItemProperty -Path "$micKey\NonPackaged" -Name Value -ErrorAction SilentlyContinue).Value
            }
        }
        Verify   = {
            $micKey = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone'
            $value  = (Get-ItemProperty -Path $micKey               -Name Value -ErrorAction SilentlyContinue).Value
            $desk   = (Get-ItemProperty -Path "$micKey\NonPackaged" -Name Value -ErrorAction SilentlyContinue).Value
            ($value -eq 'Deny') -or ($desk -eq 'Deny')
        }
        Validate = {
            $micKey = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone'
            $value  = (Get-ItemProperty -Path $micKey               -Name Value -ErrorAction SilentlyContinue).Value
            $desk   = (Get-ItemProperty -Path "$micKey\NonPackaged" -Name Value -ErrorAction SilentlyContinue).Value
            @{ Passed = ($value -ne 'Deny' -and $desk -ne 'Deny'); Detail = "Value=$value NonPackaged=$desk" }
        }
        Restore  = {
            param($Original)
            $micKey = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone'
            if ($null -eq $Original.Value) {
                Remove-ItemProperty -Path $micKey -Name Value -ErrorAction SilentlyContinue
            } else {
                Set-ItemProperty -Path $micKey -Name Value -Value $Original.Value -ErrorAction SilentlyContinue
            }
            if ($null -eq $Original.Desktop) {
                Remove-ItemProperty -Path "$micKey\NonPackaged" -Name Value -ErrorAction SilentlyContinue
            } else {
                Set-ItemProperty -Path "$micKey\NonPackaged" -Name Value -Value $Original.Desktop -ErrorAction SilentlyContinue
            }
        }
    },

    @{
        Name            = 'BluetoothServiceStopped'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        Methods         = @(
            @{
                Name  = 'StopService'
                Apply = {
                    if (-not (Get-Service -Name bthserv -ErrorAction SilentlyContinue)) { throw 'bthserv service not found on this device.' }
                    Stop-Service -Name bthserv -Force -ErrorAction Stop
                }
            }
        )
        Capture  = {
            $svc = Get-CimInstance -ClassName Win32_Service -Filter "Name='bthserv'" -ErrorAction SilentlyContinue
            if (-not $svc) { throw 'bthserv service not found; cannot test BluetoothServiceStopped.' }
            @{ StartMode = $svc.StartMode; State = $svc.State }
        }
        Verify   = { (Get-Service -Name bthserv -ErrorAction SilentlyContinue).Status -ne 'Running' }
        Validate = {
            # 'Passed' in the target script also requires a detected adapter, which is
            # unreachable on hardware without a Bluetooth radio -- check the service
            # state directly instead of the step's overall Status label.
            $status = (Get-Service -Name bthserv -ErrorAction SilentlyContinue).Status
            @{ Passed = ($status -eq 'Running'); Detail = "ServiceStatus=$status" }
        }
        Restore  = {
            param($Original)
            Set-Service -Name bthserv -StartupType (ConvertTo-StartupType $Original.StartMode) -ErrorAction SilentlyContinue
            if ($Original.State -eq 'Running') { Start-Service -Name bthserv -ErrorAction SilentlyContinue }
        }
    }
)

function Get-BreakDefinition {
    param([Parameter(Mandatory = $true)][string]$Name)
    $BreakCatalog | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
}

function Request-TestReboot {
    param([Parameter(Mandatory = $true)][hashtable]$State)

    Save-DexTestState -State $State
    Register-DexTestResume -State $State -BreakTestPath $SelfPath
    Write-DexStep -Status 'Info' -Name 'Reboot' -Message 'Rebooting to apply pending state; run resumes automatically.'
    & shutdown.exe /r /t 15 /f | Out-Null
}

# ==============================================================================
# Main
# ==============================================================================

Assert-DexTestHost -Force:$Force -ProductionDomainDenyList $ProductionDomainDenyList

Write-DexBanner -Title "Invoke-AutoRemediateAudioBluetooth_BreakTest" -Detail "Environment: $Environment"

# -- Restore-only mode ---------------------------------------------------------
if ($Restore) {
    $state = New-DexTestContext -ScriptUnderTest $ScriptUnderTest -Resume
    foreach ($b in $state.Breaks) {
        $def = Get-BreakDefinition -Name $b.Name
        if (-not $def) { continue }
        try {
            & $def.Restore ([PSCustomObject]$b.OriginalState)
            Write-DexStep -Status 'Passed' -Name "Restore $($b.Name)"
        } catch {
            Write-DexStep -Status 'Failed' -Name "Restore $($b.Name)" -Message $_.Exception.Message
        }
    }
    Unregister-DexTestResume -State $state
    $state.Phase   = 'Restored'
    $state.Overall = 'Restored'
    Write-DexTestResult -State $state | Out-Null
    Clear-DexTestState -State $state
    exit 0
}

# -- Acquire context -----------------------------------------------------------
if ($Resume) {
    $state = New-DexTestContext -ScriptUnderTest $ScriptUnderTest -Resume
    if (Test-DexRebootOccurred -State $state) {
        $state.RebootCount = [int]$state.RebootCount + 1
        Write-DexStep -Status 'Info' -Name 'Resume' -Message "Reboot #$($state.RebootCount) confirmed; resuming at phase '$($state.Phase)'."
    } else {
        Write-DexStep -Status 'Warning' -Name 'Resume' -Message 'No reboot detected since the run started.'
    }
    # RemediationTest cannot survive as a switch across the reboot, so it is
    # recovered from the state that was persisted before the machine went down.
    $RemediationTest = [bool]$state.RemediationTest
} else {
    $state = New-DexTestContext -ScriptUnderTest $ScriptUnderTest -Seed $Seed -Environment $Environment
    $state.RemediationTest = [bool]$RemediationTest
    Write-DexStep -Status 'Info' -Name 'Context' -Message "TestId $($state.TestId)  Seed $($state.Seed)"
}

$exitCode = 0

try {
    # -- Phase: apply breaks ---------------------------------------------------
    if ($state.Phase -eq 'Init') {

        $candidates = if ($BreakName) {
            @($BreakCatalog | Where-Object { $BreakName -contains $_.Name })
        } else {
            @($BreakCatalog)
        }

        if ($candidates.Count -eq 0) { throw 'No break definitions matched the requested selection.' }

        $selected = if ($BreakName) {
            $candidates
        } else {
            Get-DexRandomSubset -InputObject $candidates -Random $state.Random -Count $BreakCount
        }

        $applied = @()
        foreach ($def in $selected) {
            $method = (Get-DexRandomSubset -InputObject $def.Methods -Random $state.Random -Count 1)[0]

            $original = & $def.Capture
            & $method.Apply

            if ($def.RequiresReboot) { $state.RequiresReboot = $true }

            $applied += @{
                Name            = $def.Name
                Method          = $method.Name
                ExpectedOutcome = $def.ExpectedOutcome
                RequiresReboot  = [bool]$def.RequiresReboot
                Applied         = $true
                BreakVerified   = $false
                OriginalState   = $original
            }
            Write-DexStep -Status 'Info' -Name "Break $($def.Name)" -Message "method '$($method.Name)' applied"
        }

        $state.Breaks = $applied
        $state.Phase  = 'Broken'
        Save-DexTestState -State $state

        if ($state.RequiresReboot) {
            Request-TestReboot -State $state
            exit 0
        }
    }

    # -- Phase: verify the break -----------------------------------------------
    if ($state.Phase -eq 'Broken') {

        $allVerified = $true
        foreach ($b in $state.Breaks) {
            $def = Get-BreakDefinition -Name $b.Name
            $ok  = [bool](& $def.Verify)
            $b.BreakVerified = $ok
            if ($ok) {
                Write-DexStep -Status 'Passed' -Name "Verify $($b.Name)" -Message 'component is genuinely broken'
            } else {
                $allVerified = $false
                Write-DexStep -Status 'Failed' -Name "Verify $($b.Name)" -Message 'break did not land; remediation would be a false green'
            }
        }

        if (-not $allVerified) {
            $state.Phase   = 'BreakFailed'
            $state.Overall = 'BreakFailed'
            Save-DexTestState -State $state
            throw 'One or more breaks could not be verified; refusing to run remediation.'
        }

        $state.Phase = 'BreakVerified'
        Save-DexTestState -State $state
    }

    # -- Phase: remediate ------------------------------------------------------
    if ($state.Phase -eq 'BreakVerified') {

        if (-not $RemediationTest) {
            $state.Overall = 'BreakOnly'
            Write-DexStep -Status 'Info' -Name 'Remediation' -Message 'skipped (-RemediationTest not supplied)'
        } else {
            Write-DexStep -Status 'Info' -Name 'Remediation' -Message "invoking $([System.IO.Path]::GetFileName($RemediationScript))"

            $sw     = [System.Diagnostics.Stopwatch]::StartNew()
            $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $RemediationScript 2>&1
            $rc     = $LASTEXITCODE
            $sw.Stop()

            $state.Remediation = @{
                ExitCode    = $rc
                DurationSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
                Output      = ($output | Out-String).Trim()
            }
            $state.Phase = 'Remediated'
            Save-DexTestState -State $state

            if ($state.RequiresReboot) {
                Request-TestReboot -State $state
                exit 0
            }
        }
    }

    # -- Phase: validate -------------------------------------------------------
    if ($state.Phase -eq 'Remediated') {

        $validation = @()
        foreach ($b in $state.Breaks) {
            $def    = Get-BreakDefinition -Name $b.Name
            $result = & $def.Validate

            if ($result -is [hashtable] -or $result -is [System.Collections.IDictionary]) {
                $passed = [bool]$result.Passed
                $detail = "$($result.Detail)"
            } else {
                $passed = [bool]$result
                $detail = $null
            }

            $expected = if ($b.ExpectedOutcome -eq 'ExpectFixed') {
                'component repaired by remediation'
            } else {
                'component detected and reported, left unmodified'
            }

            $actual = if ($passed) { 'as expected' } else { 'NOT as expected' }
            if ($detail) { $actual = "$actual ($detail)" }

            $validation += @{
                Name     = $b.Name
                Expected = $expected
                Actual   = $actual
                Result   = if ($passed) { 'Pass' } else { 'Fail' }
            }
            Write-DexStep -Status $(if ($passed) { 'Passed' } else { 'Failed' }) `
                          -Name "Validate $($b.Name)" -Message "$expected $(if ($detail) { "-- $detail" })"
        }

        $state.Validation = $validation
        $state.Phase      = 'Validated'

        $failedCount = @($validation | Where-Object { $_.Result -eq 'Fail' }).Count
        $state.Overall = if ($failedCount -eq 0) {
            'Passed'
        } elseif ($state.Remediation -and [int]$state.Remediation.ExitCode -eq 0) {
            # Remediation claimed success while a component is still broken.
            'FalsePass'
        } else {
            'Failed'
        }

        Save-DexTestState -State $state
    }

} catch {
    Write-DexStep -Status 'Failed' -Name 'Harness' -Message $_.Exception.Message
    if ($state.Overall -eq 'Incomplete') { $state.Overall = 'Failed' }
    $exitCode = 1
}

# -- Restore -------------------------------------------------------------------
# Snapshot environments revert on the host, so restoring here would only add risk.
if ($Environment -eq 'Physical') {
    $restoreFailed = $false
    foreach ($b in @($state.Breaks)) {
        $def = Get-BreakDefinition -Name $b.Name
        if (-not $def) { continue }
        try {
            & $def.Restore ([PSCustomObject]$b.OriginalState)
        } catch {
            $restoreFailed = $true
            Write-DexStep -Status 'Failed' -Name "Restore $($b.Name)" -Message $_.Exception.Message
        }
    }

    if ($restoreFailed) {
        $state.Overall = 'Dirty'
        Write-DexStep -Status 'Failed' -Name 'Restore' -Message 'machine left modified -- manual cleanup required'
    } else {
        $state.Phase = 'Restored'
        Write-DexStep -Status 'Passed' -Name 'Restore' -Message 'machine returned to baseline'
    }
}

Unregister-DexTestResume -State $state

Write-Host ''
Write-DexStep -Status $(switch ($state.Overall) { 'Passed' { 'Passed' } 'BreakOnly' { 'Info' } default { 'Failed' } }) `
              -Name 'Overall' -Message $state.Overall

Write-DexTestResult -State $state | Out-Null
Clear-DexTestState -State $state

exit $exitCode
