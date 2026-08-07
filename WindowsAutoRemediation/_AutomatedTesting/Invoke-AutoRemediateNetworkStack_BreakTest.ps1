<#
.SYNOPSIS
    Invoke-AutoRemediateNetworkStack_BreakTest -- deliberately breaks lower-risk
    network stack components, then verifies Invoke-AutoRemediateNetworkStack.ps1
    actually fixes them.

.DESCRIPTION
    Break -> verify-the-break -> remediate -> validate -> restore. Writes a uniform
    JSON result to C:\Temp\FixReport\Invoke-AutoRemediateNetworkStack\ for
    Invoke-FixReportAnalysis.ps1 to aggregate.

    SCOPE (v1) -- LOWER-RISK STEPS ONLY
    This first pass covers only breaks that cannot sever the session running the
    test:
      DhcpLeaseLoss    -- releases the DHCP lease on the adapter carrying the
                          test session, which invalidates DNS Resolution (step 1),
                          Default Gateway (step 2), AND Internet Connectivity
                          (step 7) simultaneously -- they share one root cause.
                          `ipconfig /renew` (used by all three steps' own
                          resolution scripts) is what genuinely fixes this.
      FirewallDisabled -- disables all firewall profiles (step 6). Local-only,
                          no effect on the session's own connectivity.
    DEFERRED: Network Adapters (3), Winsock/IP Stack (4), and Adapter Bounce (5)
    disable/reset the adapter itself or require a reboot, and can disconnect the
    very session driving this test. They are intentionally NOT in this catalog
    yet -- planned for a follow-up pass behind an opt-in switch, matching how
    -IncludeRebootBreaks gates the Printer harness's reboot-required break.

    A DHCP LEASE RELEASE TAKES DOWN THE ADAPTER'S IP BRIEFLY. If this machine's
    only network path is the adapter being tested, a remote session (RDP/SSH)
    over that adapter may drop for the few seconds until `ipconfig /renew`
    reacquires a lease -- expected, and normally self-heals via -RemediationTest,
    but plan around it (console access, or a secondary management path).

    VERIFY-THE-BREAK
    Every break is followed by a probe proving the component is genuinely broken.
    A break that silently no-ops would let the remediation "pass" against a
    healthy machine -- a false green.

    Both breaks in this catalog are ExpectFixed: Invoke-AutoRemediateNetworkStack.ps1
    has a ResolutionScript for every one of its 7 steps (unlike the Printer
    script, none are report-only by design).

.PARAMETER RemediationTest
    After breaking, run Invoke-AutoRemediateNetworkStack.ps1 and validate the outcome.
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
    How many components to break when selecting randomly. Default 2 (this
    catalog currently has 2 entries, so the default breaks both).

.PARAMETER Restore
    Undo an in-flight run's breaks and exit. No remediation, no validation.

.PARAMETER Resume
    Internal. Used by the AtStartup task to re-enter after a reboot (unused by
    this catalog today since neither current break requires one; kept for
    symmetry with the shared framework and the deferred reboot-requiring breaks).

.PARAMETER Force
    Required acknowledgement that this machine will be broken.

.NOTES
    Script Name  : Invoke-AutoRemediateNetworkStack_BreakTest.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : Administrator (elevated)
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-07
    Reporting    : C:\Temp\FixReport\Invoke-AutoRemediateNetworkStack\

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

$ScriptUnderTest   = 'Invoke-AutoRemediateNetworkStack'
$RemediationScript = Join-Path $PSScriptRoot '..\Invoke-AutoRemediateNetworkStack.ps1'
$SelfPath          = $MyInvocation.MyCommand.Path

$modulePath = Join-Path $PSScriptRoot '..\..\_AutomatedTesting\DEXTestFramework.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    throw "DEXTestFramework.psm1 not found at $modulePath"
}
Import-Module $modulePath -Force

# -- Helpers ------------------------------------------------------------------

function Get-DhcpAdapter {
    # Deterministic pick so Capture/Apply/Verify resolve to the same adapter.
    Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
        Where-Object { $_.Status -eq 'Up' } |
        Sort-Object -Property ifIndex |
        Where-Object {
            $ipIf = Get-NetIPInterface -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
            $ipIf -and $ipIf.Dhcp -eq 'Enabled'
        } |
        Select-Object -First 1
}

function Test-NetworkStackDetection {
    <#
        Independently re-derives the outcome of steps 1 (DNS), 2 (Gateway), and
        7 (Internet) exactly as Invoke-AutoRemediateNetworkStack.ps1 checks them.
        Used by Validate rather than trusting the remediation script's own stdout.
    #>
    $dnsOk = $false
    try {
        $dns = Get-WmiObject -Class Win32_NetworkAdapterConfiguration -Filter 'IPEnabled = 1' -ErrorAction SilentlyContinue |
               Select-Object -ExpandProperty DNSServerSearchOrder | Select-Object -Unique
        if ($dns) {
            $null = Resolve-DnsName -Name 'google.com' -ErrorAction Stop
            $dnsOk = $true
        }
    } catch {}

    $gwOk = $false
    try {
        $gw = Get-WmiObject -Class Win32_NetworkAdapterConfiguration -Filter 'IPEnabled = 1' -ErrorAction SilentlyContinue |
              Select-Object -ExpandProperty DefaultIPGateway | Select-Object -First 1
        if ($gw -and (Test-Connection -ComputerName $gw -Count 2 -Quiet -ErrorAction SilentlyContinue)) { $gwOk = $true }
    } catch {}

    $inetOk = $false
    try {
        if (Test-Connection -ComputerName 8.8.8.8 -Count 2 -Quiet -ErrorAction SilentlyContinue) {
            $inetOk = $true
        } else {
            $null = Invoke-WebRequest -Uri 'https://www.msftconnecttest.com/connecttest.txt' -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
            $inetOk = $true
        }
    } catch {}

    @{
        Passed = ($dnsOk -and $gwOk -and $inetOk)
        Detail = "DNS=$dnsOk Gateway=$gwOk Internet=$inetOk"
    }
}

# -- Break definitions ---------------------------------------------------------
# Capture runs before any mutation; Restore consumes what it returned.
# Verify proves the break landed. Validate decides whether remediation did its job.
$BreakCatalog = @(

    @{
        Name             = 'DhcpLeaseLoss'
        ExpectedOutcome  = 'ExpectFixed'
        RequiresReboot   = $false
        ConnectivityRisk = $false   # release+renew is fast and self-healing
        Methods          = @(
            @{
                Name  = 'IpconfigRelease'
                Apply = {
                    $adapter = Get-DhcpAdapter
                    if (-not $adapter) { throw 'No DHCP-enabled physical adapter found.' }
                    $script:DhcpTargetAlias = $adapter.InterfaceAlias
                    & ipconfig.exe /release "$($adapter.InterfaceAlias)" | Out-Null
                }
            }
        )
        Capture  = {
            $adapter = Get-DhcpAdapter
            if (-not $adapter) { throw 'No DHCP-enabled physical adapter found; cannot test DhcpLeaseLoss.' }
            $script:DhcpTargetAlias = $adapter.InterfaceAlias
            @{ InterfaceAlias = $adapter.InterfaceAlias }
        }
        Verify   = {
            $cfg = Get-NetIPConfiguration -InterfaceAlias $script:DhcpTargetAlias -ErrorAction SilentlyContinue
            (-not $cfg) -or (-not $cfg.IPv4Address) -or (-not $cfg.IPv4DefaultGateway)
        }
        Validate = { Test-NetworkStackDetection }
        Restore  = {
            param($Original)
            & ipconfig.exe /renew "$($Original.InterfaceAlias)" | Out-Null
        }
    },

    @{
        Name             = 'FirewallDisabled'
        ExpectedOutcome  = 'ExpectFixed'
        RequiresReboot   = $false
        ConnectivityRisk = $false   # local policy only, no effect on the session's own traffic
        Methods          = @(
            @{
                Name  = 'DisableAllProfiles'
                Apply = { Set-NetFirewallProfile -All -Enabled False -ErrorAction Stop }
            }
        )
        Capture  = {
            @{ Profiles = @(Get-NetFirewallProfile -ErrorAction SilentlyContinue | Select-Object Name, Enabled) }
        }
        Verify   = {
            $enabled = @(Get-NetFirewallProfile -PolicyStore ActiveStore -ErrorAction SilentlyContinue | Where-Object { $_.Enabled })
            $enabled.Count -eq 0
        }
        Validate = {
            $enabled = @(Get-NetFirewallProfile -PolicyStore ActiveStore -ErrorAction SilentlyContinue | Where-Object { $_.Enabled })
            @{ Passed = ($enabled.Count -gt 0); Detail = "EnabledProfiles=$(($enabled.Name) -join ',')" }
        }
        Restore  = {
            param($Original)
            foreach ($p in $Original.Profiles) {
                Set-NetFirewallProfile -Name $p.Name -Enabled $p.Enabled -ErrorAction SilentlyContinue
            }
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

Write-DexBanner -Title "Invoke-AutoRemediateNetworkStack_BreakTest" -Detail "Environment: $Environment"

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
