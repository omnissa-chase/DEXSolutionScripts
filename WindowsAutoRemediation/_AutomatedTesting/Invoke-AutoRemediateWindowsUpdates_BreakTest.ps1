<#
.SYNOPSIS
    Invoke-AutoRemediateWindowsUpdates_BreakTest -- deliberately breaks Windows
    Update service-level components, then verifies
    Invoke-AutoRemediateWindowsUpdates.ps1 actually fixes them.

.DESCRIPTION
    Break -> verify-the-break -> remediate -> validate -> restore. Writes a uniform
    JSON result to C:\Temp\FixReport\Invoke-AutoRemediateWindowsUpdates\ for
    Invoke-FixReportAnalysis.ps1 to aggregate.

    SCOPE (v1) -- SERVICE-LEVEL STEPS, PLUS A SAFE DATASTORE SIMULATION
    This catalog covers the 4 of 8 target steps that are (a) backed by a real
    ResolutionScript and (b) safely and deterministically reversible:
      WuauservStopped  -- stops the Windows Update service (step 1).
      BitsDisabled      -- disables BITS, the update download engine (step 2).
      CryptSvcStopped   -- stops Cryptographic Services, required for update
                           signature verification (step 3).
      DataStoreBloated  -- simulates step 4's "DataStore.edb > 500MB" condition
                           WITHOUT ever touching the real update cache: the real
                           C:\Windows\SoftwareDistribution\DataStore folder is
                           renamed aside intact, a brand-new DataStore folder is
                           created at the real path, and a fake DataStore.edb is
                           dropped in using `fsutil sparse` so it reports as
                           ~600MB to Test-Path/Get-Item without consuming real
                           disk space. The target's own remediation (which wipes
                           the folder contents and restarts the services) only
                           ever touches this disposable fake folder. The real
                           folder is renamed back in Restore regardless of what
                           remediation did to the fake one.
    All four are standard, well-precedented troubleshooting actions (the first
    three are the same "net stop/start" steps used in SFC/DISM guides) and
    restore cleanly.

    DEFERRED, NOT IN THIS CATALOG:
      Pending Reboot Check (step 5), Windows Update Policy (step 6), and Last
        Update Date (step 8) -- ResolutionScript = $null on all three by design
        (informational only; reboot scheduling, GPO, and update installation
        all require a human or a separate maintenance window).
      Disk Space for Updates (step 7) -- remediation runs the REAL
        `cleanmgr.exe /sagerun:1`, a system-wide cleanup tool whose effect
        depends on whatever Disk Cleanup profile #1 is configured to delete on
        this machine. It can permanently remove real files unrelated to the
        break test's own filler data, so it is excluded rather than gated --
        there is no filler-file break that reliably undoes itself once
        cleanmgr has run. (Unlike DataStoreBloated, there's no way to redirect
        cleanmgr onto a disposable fake target -- it operates on the real C:
        drive by design.)

    VERIFY-THE-BREAK
    Every break is followed by a probe proving the component is genuinely
    broken. A break that silently no-ops would let the remediation "pass"
    against an already-healthy machine -- a false green.

    All four breaks in this catalog are ExpectFixed: each corresponding step
    in Invoke-AutoRemediateWindowsUpdates.ps1 has a real ResolutionScript.

    DataStoreBloated briefly stops wuauserv/BITS and renames a system folder
    while the fake data is in place -- a crash mid-run would leave the real
    DataStore sitting under a `.dextest.bak` name until the run is resumed or
    `-Restore` is used, the same transient-exposure window every other break
    in this catalog has while its service is stopped.

.PARAMETER RemediationTest
    After breaking, run Invoke-AutoRemediateWindowsUpdates.ps1 and validate the
    outcome. Without this the script breaks and reports only.

.PARAMETER Environment
    Physical (default) restores the machine when the run ends.
    Snapshot skips restore on the assumption the host reverts a checkpoint.

.PARAMETER Seed
    Replays an earlier run's random break selection exactly. Omit for a new
    random seed, which is always recorded in the result.

.PARAMETER BreakName
    Force specific breaks instead of a random selection.

.PARAMETER BreakCount
    How many components to break when selecting randomly. Default 2 (this
    catalog currently has 4 entries).

.PARAMETER Restore
    Undo an in-flight run's breaks and exit. No remediation, no validation.

.PARAMETER Resume
    Internal. Used by the AtStartup task to re-enter after a reboot (unused by
    this catalog today since none of its breaks require one; kept for symmetry
    with the shared framework).

.PARAMETER Force
    Required acknowledgement that this machine will be broken.

.NOTES
    Script Name  : Invoke-AutoRemediateWindowsUpdates_BreakTest.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : Administrator (elevated)
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-07
    Reporting    : C:\Temp\FixReport\Invoke-AutoRemediateWindowsUpdates\

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

$ScriptUnderTest   = 'Invoke-AutoRemediateWindowsUpdates'
$RemediationScript = Join-Path $PSScriptRoot '..\Invoke-AutoRemediateWindowsUpdates.ps1'
$SelfPath          = $MyInvocation.MyCommand.Path

$modulePath = Join-Path $PSScriptRoot '..\..\AutomatedTesting\DEXTestFramework.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    throw "DEXTestFramework.psm1 not found at $modulePath"
}
Import-Module $modulePath -Force

# -- Helpers ------------------------------------------------------------------
# Get-Service's StartType/Status already use the same names Set-Service accepts
# ('Automatic'/'Manual'/'Disabled', 'Running'/'Stopped'), so no string-mapping
# helper is needed here (unlike the Win32_Service-based scripts elsewhere).

function Get-DexService {
    param([Parameter(Mandatory = $true)][string]$Name)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { throw "Service '$Name' not found on this device." }
    $svc
}

# DataStoreBloated operates on a disposable stand-in, never the real folder --
# see the .DESCRIPTION block above for how the rename+sparse-file swap works.
$script:DataStorePath       = Join-Path $env:SystemRoot 'SoftwareDistribution\DataStore'
$script:DataStoreBackupPath = "$script:DataStorePath.dextest.bak"
$script:FakeDbPath          = Join-Path $script:DataStorePath 'DataStore.edb'
$script:FakeDbSizeBytes     = 600MB

# -- Break definitions ---------------------------------------------------------
# Capture runs before any mutation; Restore consumes what it returned.
# Verify proves the break landed. Validate decides whether remediation did its job.
$BreakCatalog = @(

    @{
        Name            = 'WuauservStopped'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        Methods         = @(
            @{
                Name  = 'StopService'
                Apply = { Stop-Service -Name wuauserv -Force -ErrorAction Stop }
            }
        )
        Capture  = {
            $svc = Get-DexService -Name wuauserv
            @{ StartType = "$($svc.StartType)"; Status = "$($svc.Status)" }
        }
        Verify   = {
            (Get-DexService -Name wuauserv).Status -ne 'Running'
        }
        Validate = {
            $svc = Get-DexService -Name wuauserv
            @{ Passed = ($svc.Status -eq 'Running'); Detail = "Status=$($svc.Status) StartType=$($svc.StartType)" }
        }
        Restore  = {
            param($Original)
            Set-Service -Name wuauserv -StartupType $Original.StartType -ErrorAction SilentlyContinue
            if ($Original.Status -eq 'Running') {
                Start-Service -Name wuauserv -ErrorAction SilentlyContinue
            } else {
                Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
            }
        }
    },

    @{
        Name            = 'BitsDisabled'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        Methods         = @(
            @{
                Name  = 'DisableService'
                Apply = { Set-Service -Name BITS -StartupType Disabled -ErrorAction Stop }
            }
        )
        Capture  = {
            $svc = Get-DexService -Name BITS
            @{ StartType = "$($svc.StartType)"; Status = "$($svc.Status)" }
        }
        Verify   = {
            (Get-DexService -Name BITS).StartType -eq 'Disabled'
        }
        Validate = {
            $svc = Get-DexService -Name BITS
            @{ Passed = ($svc.StartType -ne 'Disabled' -and $svc.Status -eq 'Running'); Detail = "Status=$($svc.Status) StartType=$($svc.StartType)" }
        }
        Restore  = {
            param($Original)
            Set-Service -Name BITS -StartupType $Original.StartType -ErrorAction SilentlyContinue
            if ($Original.Status -eq 'Running') {
                Start-Service -Name BITS -ErrorAction SilentlyContinue
            } else {
                Stop-Service -Name BITS -Force -ErrorAction SilentlyContinue
            }
        }
    },

    @{
        Name            = 'CryptSvcStopped'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        Methods         = @(
            @{
                Name  = 'StopService'
                Apply = { Stop-Service -Name CryptSvc -Force -ErrorAction Stop }
            }
        )
        Capture  = {
            $svc = Get-DexService -Name CryptSvc
            @{ StartType = "$($svc.StartType)"; Status = "$($svc.Status)" }
        }
        Verify   = {
            (Get-DexService -Name CryptSvc).Status -ne 'Running'
        }
        Validate = {
            $svc = Get-DexService -Name CryptSvc
            @{ Passed = ($svc.Status -eq 'Running'); Detail = "Status=$($svc.Status)" }
        }
        Restore  = {
            param($Original)
            Set-Service -Name CryptSvc -StartupType $Original.StartType -ErrorAction SilentlyContinue
            if ($Original.Status -eq 'Running') {
                Start-Service -Name CryptSvc -ErrorAction SilentlyContinue
            } else {
                Stop-Service -Name CryptSvc -Force -ErrorAction SilentlyContinue
            }
        }
    },

    @{
        Name            = 'DataStoreBloated'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        Methods         = @(
            @{
                Name  = 'InjectSparseOversizedFile'
                Apply = {
                    # Real folder moves aside intact; only the fake replacement is ever touched.
                    Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
                    Stop-Service -Name BITS     -Force -ErrorAction SilentlyContinue
                    Rename-Item -LiteralPath $script:DataStorePath `
                        -NewName (Split-Path -Path $script:DataStoreBackupPath -Leaf) -ErrorAction Stop
                    New-Item -ItemType Directory -Path $script:DataStorePath -Force | Out-Null
                    & fsutil.exe file createnew $script:FakeDbPath $script:FakeDbSizeBytes   | Out-Null
                    & fsutil.exe sparse setflag  $script:FakeDbPath                          | Out-Null
                    & fsutil.exe sparse setrange $script:FakeDbPath 0 $script:FakeDbSizeBytes | Out-Null
                }
            }
        )
        Capture  = {
            if (-not (Test-Path -LiteralPath $script:DataStorePath)) {
                throw 'SoftwareDistribution\DataStore not found; cannot test DataStoreBloated.'
            }
            if (Test-Path -LiteralPath $script:DataStoreBackupPath) {
                throw "Leftover backup at $script:DataStoreBackupPath from a previous run; resolve manually before testing DataStoreBloated."
            }
            $freeBytes = (Get-PSDrive -Name $env:SystemDrive.TrimEnd(':')).Free
            if ($freeBytes -lt 1GB) {
                throw "Less than 1GB free on $env:SystemDrive; refusing to test DataStoreBloated."
            }
            $wu   = Get-DexService -Name wuauserv
            $bits = Get-DexService -Name BITS
            @{
                WuauservStartType = "$($wu.StartType)"
                WuauservStatus    = "$($wu.Status)"
                BitsStartType     = "$($bits.StartType)"
                BitsStatus        = "$($bits.Status)"
            }
        }
        Verify   = {
            (Test-Path -LiteralPath $script:FakeDbPath) -and
                ((Get-Item -LiteralPath $script:FakeDbPath).Length / 1MB) -gt 500
        }
        Validate = {
            $exists  = Test-Path -LiteralPath $script:FakeDbPath
            $bloated = $exists -and ((Get-Item -LiteralPath $script:FakeDbPath).Length / 1MB) -gt 500
            $detail  = if ($exists) {
                "DataStore.edb still present, $([math]::Round((Get-Item -LiteralPath $script:FakeDbPath).Length / 1MB, 1))MB"
            } else {
                'DataStore.edb cleared'
            }
            @{ Passed = -not $bloated; Detail = $detail }
        }
        Restore  = {
            param($Original)
            Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
            Stop-Service -Name BITS     -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $script:DataStorePath) {
                Remove-Item -LiteralPath $script:DataStorePath -Recurse -Force -ErrorAction SilentlyContinue
            }
            Rename-Item -LiteralPath $script:DataStoreBackupPath `
                -NewName (Split-Path -Path $script:DataStorePath -Leaf) -ErrorAction Stop
            Set-Service -Name wuauserv -StartupType $Original.WuauservStartType -ErrorAction SilentlyContinue
            Set-Service -Name BITS     -StartupType $Original.BitsStartType     -ErrorAction SilentlyContinue
            if ($Original.WuauservStatus -eq 'Running') { Start-Service -Name wuauserv -ErrorAction SilentlyContinue }
            if ($Original.BitsStatus     -eq 'Running') { Start-Service -Name BITS     -ErrorAction SilentlyContinue }
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

Write-DexBanner -Title "Invoke-AutoRemediateWindowsUpdates_BreakTest" -Detail "Environment: $Environment"

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
