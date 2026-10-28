<#
.SYNOPSIS
    Unit tests for Invoke-AutoRemediateAllDriverIssues.ps1 (non-destructive, no elevation).

.DESCRIPTION
    Runs the script as a file in a child Windows PowerShell 5.1 process with WMI,
    pnputil and Start-Sleep stubbed (see DriverTestKit.ps1). Covers classification,
    the escalation chain, filter handling, argument forwarding, summary counts and
    exit codes. Compatible with the in-box Pester 3.4 and with Pester 5.

    Exit-code contract under test:
        0  every step Passed/Warning, nothing to fix
        1  at least one step Failed (even if remediation then fixed it)
        2  at least one device remained in error after the escalation chain

.NOTES
    Run with ..\Unit\Invoke-DriverUnitTests.ps1 or:  Invoke-Pester -Script <this folder>
#>

. (Join-Path $PSScriptRoot 'DriverTestKit.ps1')

$ScriptUnderTest = (Resolve-Path (Join-Path $PSScriptRoot '..\..\Invoke-AutoRemediateAllDriverIssues.ps1')).Path

# A small fleet with one device in every class the sweep remediates.
function New-HealthyFleet {
    @(
        (New-FakeDevice -Name 'Realtek High Definition Audio'               -DeviceID 'HDAUDIO\FAKE\AUDIO1')
        (New-FakeDevice -Name 'Intel(R) Ethernet Connection I219-LM'       -DeviceID 'PCI\FAKE\NIC1')
        (New-FakeDevice -Name 'Standard SATA AHCI Controller'              -DeviceID 'PCI\FAKE\AHCI1')
        (New-FakeDevice -Name 'Intel(R) USB 3.1 eXtensible Host Controller' -DeviceID 'PCI\FAKE\XHCI1')
    )
}

function New-FleetWithErroredAudio {
    param([int]$Code = 10)
    $f = New-HealthyFleet
    $f[0].ConfigManagerErrorCode = $Code
    $f
}

Describe 'Invoke-AutoRemediateAllDriverIssues -- runtime scoping (UEM regression)' {

    It 'runs as a file without any "not recognized" errors from helper functions' {
        $run = Invoke-DriverScriptUnderStubs -ScriptPath $ScriptUnderTest -Devices (New-HealthyFleet)
        Assert-OutputLacks -Run $run -Pattern 'is not recognized'
        Assert-OutputLacks -Run $run -Pattern 'Detection exception'
        Assert-OutputLacks -Run $run -Pattern 'Remediation ERROR'
    }

    It 'binds each class step to its own class (no shared closure variable)' {
        $run = Invoke-DriverScriptUnderStubs -ScriptPath $ScriptUnderTest -Devices (New-HealthyFleet)
        Assert-OutputContains -Run $run -Pattern 'Audio Driver Health: Healthy Audio driver\(s\): Realtek'
        Assert-OutputContains -Run $run -Pattern 'Network Adapter Driver Health: Healthy Network Adapter driver\(s\): Intel'
        Assert-OutputContains -Run $run -Pattern 'Storage Controller Driver Health: Healthy Storage Controller driver\(s\): Standard SATA'
        Assert-OutputContains -Run $run -Pattern 'USB / Dock Driver Health: Healthy USB / Dock driver\(s\): Intel\(R\) USB'
    }
}

Describe 'Invoke-AutoRemediateAllDriverIssues -- healthy fleet' {

    $run = Invoke-DriverScriptUnderStubs -ScriptPath $ScriptUnderTest -Devices (New-HealthyFleet)

    It 'exits 0' { Assert-Equal 0 $run.ExitCode 'exit code' }

    It 'reports zero failures and zero remediations' {
        Assert-OutputContains -Run $run -Pattern 'Failed: 0\s+\|\s+Remediations run: 0'
    }

    It 'touches pnputil only for the driver-store enumeration' {
        Assert-PnpCalled    -Run $run -Pattern '^/enum-drivers'
        Assert-PnpNotCalled -Run $run -Pattern '^/(scan-devices|restart-device|rollback-driver|remove-device)'
    }

    It 'reports the driver-store package count from pnputil' {
        Assert-OutputContains -Run $run -Pattern 'Driver Store Scan: 3 OEM driver package\(s\)'
    }
}

Describe 'Invoke-AutoRemediateAllDriverIssues -- escalation chain' {

    It 'stops at Scan when scan-devices clears the error' {
        $run = Invoke-DriverScriptUnderStubs -ScriptPath $ScriptUnderTest -Devices (New-FleetWithErroredAudio) -FixOn 'scan-devices'
        Assert-OutputContains -Run $run -Pattern 'Audio Driver Health: Driver error on: Realtek High Definition Audio \[code 10\]\s+-> Remediation ran'
        Assert-PnpCalled    -Run $run -Pattern '^/scan-devices'
        Assert-PnpNotCalled -Run $run -Pattern '^/restart-device'
        Assert-PnpNotCalled -Run $run -Pattern '^/rollback-driver'
        Assert-OutputLacks  -Run $run -Pattern 'could not be resolved'
        Assert-Equal 1 $run.ExitCode 'exit code (a Failed step was detected, then fixed)'
    }

    It 'escalates Scan -> Restart -> Rollback in order and leaves Reinstall off by default' {
        $run = Invoke-DriverScriptUnderStubs -ScriptPath $ScriptUnderTest -Devices (New-FleetWithErroredAudio)
        Assert-PnpOrder -Run $run -Verbs @('scan-devices', 'restart-device HDAUDIO\FAKE\AUDIO1', 'rollback-driver HDAUDIO\FAKE\AUDIO1')
        Assert-PnpNotCalled -Run $run -Pattern '^/remove-device'
    }

    It 'exits 2 and lists the instance id when nothing clears the error' {
        $run = Invoke-DriverScriptUnderStubs -ScriptPath $ScriptUnderTest -Devices (New-FleetWithErroredAudio)
        Assert-Equal 2 $run.ExitCode 'exit code'
        Assert-OutputContains -Run $run -Pattern '\[NOTICE\] The following device\(s\) could not be resolved without a reboot'
        Assert-OutputContains -Run $run -Pattern 'HDAUDIO\\FAKE\\AUDIO1'
    }

    It 'runs Reinstall (remove + scan) when it is explicitly allowed' {
        $run = Invoke-DriverScriptUnderStubs -ScriptPath $ScriptUnderTest -Devices (New-FleetWithErroredAudio) -FixOn 'remove-device' `
                   -ScriptParams @{ AllowedActions = @('Scan', 'Restart', 'Rollback', 'Reinstall') }
        Assert-PnpOrder -Run $run -Verbs @('scan-devices', 'restart-device', 'rollback-driver', 'remove-device HDAUDIO\FAKE\AUDIO1', 'scan-devices')
        Assert-OutputLacks -Run $run -Pattern 'could not be resolved'
        Assert-Equal 1 $run.ExitCode 'exit code'
    }

    It 'treats Uninstall as resolved without re-enumerating' {
        $run = Invoke-DriverScriptUnderStubs -ScriptPath $ScriptUnderTest -Devices (New-FleetWithErroredAudio) `
                   -ScriptParams @{ AllowedActions = @('Uninstall') }
        Assert-PnpCalled    -Run $run -Pattern '^/remove-device HDAUDIO\\FAKE\\AUDIO1'
        Assert-PnpNotCalled -Run $run -Pattern '^/scan-devices'
        Assert-OutputLacks  -Run $run -Pattern 'could not be resolved'
        Assert-Equal 1 $run.ExitCode 'exit code'
    }
}

Describe 'Invoke-AutoRemediateAllDriverIssues -- argument forwarding (break-test harness contract)' {

    It 'honours -AllowedActions passed on the command line' {
        $run = Invoke-DriverScriptUnderStubs -ScriptPath $ScriptUnderTest -Devices (New-FleetWithErroredAudio) `
                   -ScriptParams @{ AllowedActions = @('Scan') }
        Assert-OutputContains -Run $run -Pattern '(?m)^\s+Actions: Scan\s*$'
        Assert-PnpCalled    -Run $run -Pattern '^/scan-devices'
        Assert-PnpNotCalled -Run $run -Pattern '^/restart-device'
        Assert-PnpNotCalled -Run $run -Pattern '^/rollback-driver'
        Assert-Equal 2 $run.ExitCode 'exit code'
    }

    It 'honours -DriverFilter passed on the command line' {
        $run = Invoke-DriverScriptUnderStubs -ScriptPath $ScriptUnderTest -Devices (New-FleetWithErroredAudio) `
                   -ScriptParams @{ DriverFilter = 'Intel' }
        Assert-OutputContains -Run $run -Pattern 'Within-class filter: Intel'
        Assert-OutputContains -Run $run -Pattern "No Audio devices match filter 'Intel' -- step skipped"
        Assert-PnpNotCalled -Run $run -Pattern '^/restart-device'
    }
}

Describe 'Invoke-AutoRemediateAllDriverIssues -- DriverFilter via environment variable (UEM delivery)' {

    It 'skips errored devices outside the filter and does not remediate them' {
        $run = Invoke-DriverScriptUnderStubs -ScriptPath $ScriptUnderTest -Devices (New-FleetWithErroredAudio) -DriverFilter 'Intel'
        Assert-OutputContains -Run $run -Pattern "No Audio devices match filter 'Intel' -- step skipped"
        Assert-OutputContains -Run $run -Pattern 'Uncovered Device Errors: No uncovered device driver errors detected'
        Assert-PnpNotCalled -Run $run -Pattern '^/(scan-devices|restart-device|rollback-driver)'
        Assert-Equal 0 $run.ExitCode 'exit code'
    }

    It 'still remediates errored devices inside the filter' {
        $run = Invoke-DriverScriptUnderStubs -ScriptPath $ScriptUnderTest -Devices (New-FleetWithErroredAudio) -DriverFilter 'Realtek' -FixOn 'restart-device'
        Assert-PnpCalled -Run $run -Pattern '^/restart-device HDAUDIO\\FAKE\\AUDIO1'
        Assert-OutputLacks -Run $run -Pattern 'could not be resolved'
    }
}

Describe 'Invoke-AutoRemediateAllDriverIssues -- uncovered devices' {

    $fleet = New-HealthyFleet
    $fleet += New-FakeDevice -Name 'Base System Device' -DeviceID 'PCI\FAKE\UNKNOWN1' -ErrorCode 28
    $run = Invoke-DriverScriptUnderStubs -ScriptPath $ScriptUnderTest -Devices $fleet

    It 'flags an errored device outside every class as a Warning' {
        Assert-OutputContains -Run $run -Pattern '\[Warning\] Uncovered Device Errors: Errored device\(s\) outside covered classes: Base System Device \[code 28\]'
    }

    It 'does not attempt remediation on an unclassified device' {
        Assert-PnpNotCalled -Run $run -Pattern '^/(scan-devices|restart-device|rollback-driver|remove-device)'
    }

    It 'exits 0 because a Warning is not a failure' { Assert-Equal 0 $run.ExitCode 'exit code' }
}

Describe 'Invoke-AutoRemediateAllDriverIssues -- summary counts (PS 5.1 single-object .Count regression)' {

    $run = Invoke-DriverScriptUnderStubs -ScriptPath $ScriptUnderTest -Devices (New-FleetWithErroredAudio) -FixOn 'rollback-driver'

    It 'prints a numeric count when exactly one step fails' {
        Assert-OutputContains -Run $run -Pattern 'Failed: 1\s+\|'
    }

    It 'prints a numeric count when exactly one remediation runs' {
        Assert-OutputContains -Run $run -Pattern 'Remediations run: 1'
    }

    It 'exits 1 (not 0) on exactly one failed step' { Assert-Equal 1 $run.ExitCode 'exit code' }
}
