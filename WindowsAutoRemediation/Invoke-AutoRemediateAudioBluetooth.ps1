<#
.SYNOPSIS
    Invoke-AutoRemediateAudioBluetooth -- Automated audio and Bluetooth diagnostic and remediation.

.DESCRIPTION
    Runs a hard-coded sequence of audio and Bluetooth health checks and automatically
    executes the corresponding remediation for any step that fails (or warns,
    when ResolveOnWarning is set). Fully self-contained -- no JSON, no UI, no
    external dependencies. Designed for deployment as a Workspace ONE MDM
    remediation script or standalone admin tool.

    +------+----------------------------------+----------------------------------+
    | Step | Name                             | Remediates On                    |
    +------+----------------------------------+----------------------------------+
    |  1   | Audio Services                   | Failed                           |
    |  2   | Audio Driver Health              | Failed                           |
    |  3   | Default Audio Output Device      | -- (informational only)           |
    |  4   | Volume & Mute State              | Warning (ResolveOnWarning)       |
    |  5   | Microphone Access Policy         | Failed                           |
    |  6   | Bluetooth Service                | Failed                           |
    |  7   | Bluetooth Device Pairing         | -- (informational only)           |
    |  8   | Bluetooth Audio Profile          | -- (informational only)           |
    +------+----------------------------------+----------------------------------+

    Each step returns @{ Status = 'Passed'|'Warning'|'Failed'; Message = '...' }
    Resolution scripts run silently; errors are captured and reported at the end.

.NOTES
    Script Name  : Invoke-AutoRemediateAudioBluetooth.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-07-10
    Timeout      : 60 seconds

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

# -- Step Definitions ----------------------------------------------------------
# Only supported fields: Name, Order, Enabled, ResolveOnWarning,
#                        DetectionScript, ResolutionScript
$Steps = @(

    @{
        Name             = 'Audio Services'
        Order            = 1
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            # Both AudioSrv and AudioEndpointBuilder must be running for audio to function.
            # AudioEndpointBuilder must start before AudioSrv -- resolution respects this order.
            $audioSvc = Get-Service -Name AudioSrv              -ErrorAction SilentlyContinue
            $epSvc    = Get-Service -Name AudioEndpointBuilder  -ErrorAction SilentlyContinue

            if (-not $audioSvc -or -not $epSvc) {
                return @{ Status = 'Failed'; Message = 'One or more audio services not found on this device' }
            }
            if ($audioSvc.Status -ne 'Running') {
                return @{ Status = 'Failed'; Message = "AudioSrv is $($audioSvc.Status)" }
            }
            if ($epSvc.Status -ne 'Running') {
                return @{ Status = 'Failed'; Message = "AudioEndpointBuilder is $($epSvc.Status)" }
            }
            return @{ Status = 'Passed'; Message = 'AudioSrv and AudioEndpointBuilder are running' }
        }
        ResolutionScript = {
            # Endpoint builder must start first -- AudioSrv depends on it
            Stop-Service  -Name AudioSrv             -Force -ErrorAction SilentlyContinue
            Stop-Service  -Name AudioEndpointBuilder -Force -ErrorAction SilentlyContinue
            Start-Sleep   -Seconds 2
            Start-Service -Name AudioEndpointBuilder       -ErrorAction SilentlyContinue
            Start-Service -Name AudioSrv                   -ErrorAction SilentlyContinue
        }
    },

    @{
        Name             = 'Audio Driver Health'
        Order            = 2
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            # Check PnP-enumerated audio devices for non-zero ConfigManagerErrorCode (driver errors)
            $audioDevices = Get-WmiObject -Class Win32_PnPEntity -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.Name -match 'audio|sound|speaker|headset|realtek|conexant|IDT|Synaptics.*audio|Intel.*Smart Sound'
                }
            if (-not $audioDevices) {
                return @{ Status = 'Warning'; Message = 'No audio PnP devices found in hardware enumeration' }
            }
            $errored = $audioDevices | Where-Object { $_.ConfigManagerErrorCode -ne 0 }
            if ($errored) {
                $names = ($errored.Name) -join ', '
                return @{ Status = 'Failed'; Message = "Driver error on: $names" }
            }
            $names = ($audioDevices.Name) -join ', '
            return @{ Status = 'Passed'; Message = "Healthy driver(s): $names" }
        }
        ResolutionScript = {
            # Attempt an in-place driver refresh by restarting the audio PnP devices via pnputil
            $audioDevices = Get-WmiObject -Class Win32_PnPEntity -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.Name -match 'audio|sound|speaker|headset|realtek|conexant|IDT|Synaptics.*audio|Intel.*Smart Sound' -and
                    $_.ConfigManagerErrorCode -ne 0
                }
            foreach ($dev in $audioDevices) {
                # Disable then re-enable device via devcon-equivalent PnP restart
                $devId = $dev.DeviceID
                pnputil /restart-device "$devId" 2>&1 | Out-Null
            }
        }
    },

    @{
        Name             = 'Default Audio Output Device'
        Order            = 3
        Enabled          = $true
        ResolveOnWarning = $false   # Cannot silently set a default device -- informational only
        DetectionScript  = {
            $endpoints = Get-WmiObject -Query 'SELECT * FROM Win32_SoundDevice' -ErrorAction SilentlyContinue
            if (-not $endpoints) {
                return @{ Status = 'Failed'; Message = 'No sound devices found in WMI' }
            }
            # StatusInfo 3 = Enabled
            $active = $endpoints | Where-Object { $_.StatusInfo -eq 3 }
            if ($active) {
                $names = ($active.Name) -join ', '
                return @{ Status = 'Passed'; Message = "Active output device(s): $names" }
            }
            $names = ($endpoints.Name) -join ', '
            return @{ Status = 'Warning'; Message = "Device(s) found but status unconfirmed: $names" }
        }
        ResolutionScript = $null   # Intentionally no auto-remediation -- requires user selection in Sound settings
    },

    @{
        Name             = 'Volume & Mute State'
        Order            = 4
        Enabled          = $true
        # Volume at 0% returns Warning -- auto-unmute via WScript.Shell SendKeys as a best-effort fix
        ResolveOnWarning = $true
        DetectionScript  = {
            try {
                Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public class AudioUtils {
    [DllImport("winmm.dll")] public static extern int waveOutGetVolume(System.IntPtr h, out uint vol);
}
'@ -ErrorAction SilentlyContinue

                $vol    = [uint32]0
                $null   = [AudioUtils]::waveOutGetVolume([System.IntPtr]::Zero, [ref]$vol)
                $left   = $vol -band 0xFFFF
                $pct    = [math]::Round($left / 0xFFFF * 100)

                if ($pct -eq 0) {
                    return @{ Status = 'Warning'; Message = 'System volume is at 0% (muted or silent)' }
                }
                return @{ Status = 'Passed'; Message = "System volume at $pct%" }
            } catch {
                return @{ Status = 'Warning'; Message = "Unable to query volume level: $($_.Exception.Message)" }
            }
        }
        ResolutionScript = {
            # Send the mute toggle key via WScript.Shell as a best-effort unmute
            $wsh = New-Object -ComObject WScript.Shell -ErrorAction SilentlyContinue
            if ($wsh) { $wsh.SendKeys([char]0xAD) }   # VK_VOLUME_MUTE
        }
    },

    @{
        Name             = 'Microphone Access Policy'
        Order            = 5
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            # Check HKCU privacy consent store -- runs under SYSTEM so reads the default user hive
            $micKey     = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone'
            $value      = (Get-ItemProperty -Path $micKey -Name Value       -ErrorAction SilentlyContinue).Value
            $desktopVal = (Get-ItemProperty -Path "$micKey\NonPackaged" -Name Value -ErrorAction SilentlyContinue).Value

            if ($value -eq 'Deny') {
                return @{ Status = 'Failed'; Message = 'Microphone access is denied globally for this user' }
            }
            if ($desktopVal -eq 'Deny') {
                return @{ Status = 'Failed'; Message = 'Microphone access denied for desktop (Win32) apps' }
            }
            return @{ Status = 'Passed'; Message = 'Microphone access is allowed for this user' }
        }
        ResolutionScript = {
            # Re-enable microphone access in the registry consent store
            $micKey = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone'
            Set-ItemProperty -Path $micKey               -Name Value -Value 'Allow' -ErrorAction SilentlyContinue
            Set-ItemProperty -Path "$micKey\NonPackaged" -Name Value -Value 'Allow' -ErrorAction SilentlyContinue
        }
    },

    @{
        Name             = 'Bluetooth Service'
        Order            = 6
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            $svc = Get-Service -Name bthserv -ErrorAction SilentlyContinue
            if (-not $svc) {
                # Not all hardware has Bluetooth -- treat as informational Warning rather than hard fail
                return @{ Status = 'Warning'; Message = 'Bluetooth service (bthserv) not present -- adapter may not exist' }
            }
            if ($svc.Status -ne 'Running') {
                return @{ Status = 'Failed'; Message = "Bluetooth service is $($svc.Status)" }
            }
            # Confirm a Bluetooth adapter with no driver error is present
            $adapter = Get-WmiObject -Class Win32_PnPEntity -ErrorAction SilentlyContinue |
                       Where-Object { $_.Name -match 'Bluetooth' -and $_.ConfigManagerErrorCode -eq 0 }
            if ($adapter) {
                return @{ Status = 'Passed'; Message = 'Bluetooth service running, adapter detected' }
            }
            return @{ Status = 'Warning'; Message = 'Bluetooth service running but no healthy adapter confirmed' }
        }
        ResolutionScript = {
            Set-Service  -Name bthserv -StartupType Automatic -ErrorAction SilentlyContinue
            Start-Service -Name bthserv                       -ErrorAction SilentlyContinue
        }
    },

    @{
        Name             = 'Bluetooth Device Pairing'
        Order            = 7
        Enabled          = $true
        ResolveOnWarning = $false   # Cannot auto-pair -- informational only
        DetectionScript  = {
            # Enumerate paired devices from the BTHPORT registry key
            $radioKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\BTHPORT\Parameters\Devices'
            if (-not (Test-Path $radioKey)) {
                return @{ Status = 'Warning'; Message = 'No Bluetooth devices found in registry (no devices paired)' }
            }
            $devices = Get-ChildItem $radioKey -ErrorAction SilentlyContinue
            if (-not $devices) {
                return @{ Status = 'Warning'; Message = 'No paired Bluetooth devices found' }
            }
            return @{ Status = 'Passed'; Message = "$($devices.Count) paired Bluetooth device(s) registered" }
        }
        ResolutionScript = $null   # Intentionally no auto-remediation -- pairing requires physical interaction
    },

    @{
        Name             = 'Bluetooth Audio Profile'
        Order            = 8
        Enabled          = $true
        ResolveOnWarning = $false   # Profile activation requires user interaction -- informational only
        DetectionScript  = {
            # Check WMI for a Bluetooth sound device (A2DP/HFP profile active)
            $btAudio = Get-WmiObject -Class Win32_SoundDevice -ErrorAction SilentlyContinue |
                       Where-Object { $_.Name -match 'Bluetooth|BT|Headset|Headphones' }
            if ($btAudio) {
                $names = ($btAudio.Name) -join ', '
                return @{ Status = 'Passed'; Message = "Bluetooth audio endpoint active: $names" }
            }
            # Fallback: check PnP for HFP/A2DP profile nodes
            $btPnp = Get-WmiObject -Class Win32_PnPEntity -ErrorAction SilentlyContinue |
                     Where-Object { $_.Name -match 'Bluetooth.*audio|Hands.Free|A2DP|Headset' }
            if ($btPnp) {
                $names = ($btPnp.Name) -join ', '
                return @{ Status = 'Passed'; Message = "Bluetooth audio profile node found: $names" }
            }
            return @{ Status = 'Warning'; Message = 'No Bluetooth audio endpoint detected -- device may not be connected' }
        }
        ResolutionScript = $null   # Intentionally no auto-remediation -- requires user to connect BT device
    }
)

# -- Execution Engine ----------------------------------------------------------
$activeSteps = $Steps |
    Where-Object { $_.Enabled } |
    Sort-Object   { [int]$_.Order }

$results = New-Object 'System.Collections.Generic.List[PSCustomObject]'

Write-Host "`n-- Invoke-AutoRemediateAudioBluetooth ---------------------------" -ForegroundColor Cyan
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
