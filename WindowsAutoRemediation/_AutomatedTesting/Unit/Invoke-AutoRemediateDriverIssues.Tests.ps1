<#
.SYNOPSIS
    Unit tests for Invoke-AutoRemediateDriverIssues.ps1 (non-destructive, no elevation).

.DESCRIPTION
    Runs the script as a file in a child Windows PowerShell 5.1 process with WMI,
    pnputil and Start-Sleep stubbed (see DriverTestKit.ps1). Covers the required-filter
    guard, filter matching, the escalation chain, argument forwarding and exit codes.
    Compatible with the in-box Pester 3.4 and with Pester 5.

    Exit-code contract under test:
        0  no matching devices, all healthy, or every errored device fixed
        1  -DriverFilter missing
        2  at least one device remained in error after the escalation chain

.NOTES
    Run with ..\Unit\Invoke-DriverUnitTests.ps1 or:  Invoke-Pester -Script <this folder>
#>

. (Join-Path $PSScriptRoot 'DriverTestKit.ps1')

$ScriptUnderTest = (Resolve-Path (Join-Path $PSScriptRoot '..\..\Invoke-AutoRemediateDriverIssues.ps1')).Path

function New-Fleet {
    param([int]$AudioCode = 0, [int]$NicCode = 0)
    @(
        (New-FakeDevice -Name 'Realtek High Definition Audio'         -DeviceID 'HDAUDIO\FAKE\AUDIO1' -ErrorCode $AudioCode)
        (New-FakeDevice -Name 'Intel(R) Ethernet Connection I219-LM' -DeviceID 'PCI\FAKE\NIC1'       -ErrorCode $NicCode)
        (New-FakeDevice -Name 'Standard SATA AHCI Controller'        -DeviceID 'PCI\FAKE\AHCI1')
    )
}

Describe 'Invoke-AutoRemediateDriverIssues -- input guard' {

    It 'exits 1 with a clear message when no filter is supplied by env var or argument' {
        $run = Invoke-DriverScriptUnderStubs -ScriptPath $ScriptUnderTest -Devices (New-Fleet)
        Assert-Equal 1 $run.ExitCode 'exit code'
        Assert-OutputContains -Run $run -Pattern '-DriverFilter is required'
        Assert-PnpNotCalled -Run $run -Pattern '.'
    }
}

Describe 'Invoke-AutoRemediateDriverIssues -- filter matching' {

    It 'warns and exits 0 when the filter matches nothing' {
        $run = Invoke-DriverScriptUnderStubs -ScriptPath $ScriptUnderTest -Devices (New-Fleet) -DriverFilter 'ZZZ_NO_SUCH_DEVICE'
        Assert-Equal 0 $run.ExitCode 'exit code'
        Assert-OutputContains -Run $run -Pattern "\[WARNING\] No PnP devices found matching 'ZZZ_NO_SUCH_DEVICE'"
    }

    It 'reports healthy and exits 0 when matched devices have no error' {
        $run = Invoke-DriverScriptUnderStubs -ScriptPath $ScriptUnderTest -Devices (New-Fleet) -DriverFilter 'Realtek'
        Assert-Equal 0 $run.ExitCode 'exit code'
        Assert-OutputContains -Run $run -Pattern 'Matched 1 device\(s\)'
        Assert-OutputContains -Run $run -Pattern '\[OK  \] Realtek High Definition Audio'
        Assert-OutputContains -Run $run -Pattern 'All matched device\(s\) are healthy'
        Assert-PnpNotCalled -Run $run -Pattern '.'
    }

    It 'supports regex OR patterns and only remediates the errored match' {
        $run = Invoke-DriverScriptUnderStubs -ScriptPath $ScriptUnderTest -Devices (New-Fleet -NicCode 43) -DriverFilter 'Realtek|Intel' -FixOn 'scan-devices'
        Assert-OutputContains -Run $run -Pattern 'Matched 2 device\(s\)'
        Assert-OutputContains -Run $run -Pattern '\[ERR 43\] Intel\(R\) Ethernet Connection I219-LM'
        Assert-OutputContains -Run $run -Pattern 'Running escalation on 1 errored device\(s\)'
        Assert-OutputContains -Run $run -Pattern 'Fixed\s+\(1\): PCI\\FAKE\\NIC1'
        Assert-Equal 0 $run.ExitCode 'exit code'
    }
}

Describe 'Invoke-AutoRemediateDriverIssues -- escalation chain' {

    It 'stops at Restart when restart-device clears the error' {
        $run = Invoke-DriverScriptUnderStubs -ScriptPath $ScriptUnderTest -Devices (New-Fleet -AudioCode 10) -DriverFilter 'Realtek' -FixOn 'restart-device'
        Assert-PnpOrder     -Run $run -Verbs @('scan-devices', 'restart-device HDAUDIO\FAKE\AUDIO1')
        Assert-PnpNotCalled -Run $run -Pattern '^/rollback-driver'
        Assert-OutputContains -Run $run -Pattern 'Fixed\s+\(1\): HDAUDIO\\FAKE\\AUDIO1'
        Assert-Equal 0 $run.ExitCode 'exit code'
    }

    It 'exits 2 with a NOTICE when Scan, Restart and Rollback all fail to clear the error' {
        $run = Invoke-DriverScriptUnderStubs -ScriptPath $ScriptUnderTest -Devices (New-Fleet -AudioCode 10) -DriverFilter 'Realtek'
        Assert-PnpOrder     -Run $run -Verbs @('scan-devices', 'restart-device', 'rollback-driver')
        Assert-PnpNotCalled -Run $run -Pattern '^/remove-device'
        Assert-OutputContains -Run $run -Pattern 'Unfixed \(1\): HDAUDIO\\FAKE\\AUDIO1'
        Assert-OutputContains -Run $run -Pattern '\[NOTICE\] The following device\(s\) could not be resolved without a reboot'
        Assert-Equal 2 $run.ExitCode 'exit code'
    }
}

Describe 'Invoke-AutoRemediateDriverIssues -- argument forwarding (break-test harness contract)' {

    It 'accepts -DriverFilter on the command line instead of the environment variable' {
        $run = Invoke-DriverScriptUnderStubs -ScriptPath $ScriptUnderTest -Devices (New-Fleet) -ScriptParams @{ DriverFilter = 'Realtek' }
        Assert-Equal 0 $run.ExitCode 'exit code'
        Assert-OutputContains -Run $run -Pattern 'Filter: Realtek'
        Assert-OutputContains -Run $run -Pattern 'All matched device\(s\) are healthy'
    }

    It 'accepts -AllowedActions on the command line (Reinstall path)' {
        $run = Invoke-DriverScriptUnderStubs -ScriptPath $ScriptUnderTest -Devices (New-Fleet -AudioCode 10) -FixOn 'remove-device' `
                   -ScriptParams @{ DriverFilter = 'Realtek'; AllowedActions = @('Scan', 'Restart', 'Rollback', 'Reinstall') }
        Assert-OutputContains -Run $run -Pattern 'Actions: Scan, Restart, Rollback, Reinstall'
        Assert-PnpOrder -Run $run -Verbs @('scan-devices', 'restart-device', 'rollback-driver', 'remove-device HDAUDIO\FAKE\AUDIO1', 'scan-devices')
        Assert-OutputContains -Run $run -Pattern 'Fixed\s+\(1\)'
        Assert-Equal 0 $run.ExitCode 'exit code'
    }

    It 'treats Uninstall as resolved without re-enumerating' {
        $run = Invoke-DriverScriptUnderStubs -ScriptPath $ScriptUnderTest -Devices (New-Fleet -AudioCode 10) `
                   -ScriptParams @{ DriverFilter = 'Realtek'; AllowedActions = @('Uninstall') }
        Assert-PnpCalled    -Run $run -Pattern '^/remove-device HDAUDIO\\FAKE\\AUDIO1'
        Assert-PnpNotCalled -Run $run -Pattern '^/scan-devices'
        Assert-OutputContains -Run $run -Pattern 'Fixed\s+\(1\)'
        Assert-Equal 0 $run.ExitCode 'exit code'
    }
}
