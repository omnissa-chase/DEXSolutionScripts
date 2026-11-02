<#
.SYNOPSIS
    Invoke-DefenderDynamicPerformance_BreakTest -- deliberately drifts Defender's scan
    CPU settings and corrupts the cached performance score, then verifies
    Invoke-DefenderDynamicPerformance.ps1 re-applies the right profile.

.DESCRIPTION
    Break -> verify-the-break -> remediate -> validate -> restore. Writes a uniform
    JSON result to C:\Temp\FixReport\Invoke-DefenderDynamicPerformance\ for
    Invoke-FixReportAnalysis.ps1 to aggregate.

    THIS SCRIPT IS DELIBERATELY DESTRUCTIVE. It changes Microsoft Defender scan
    preferences (ScanAvgCPULoadFactor, EnableLowCpuPriority,
    DisableCpuThrottleOnIdleScans) and rewrites the AirWatch HealthDetection cache.
    Real-time protection is never touched. Run it only on a disposable VM or a
    marked test host. See Assert-DexTestHost in DEXTestFramework.psm1.

    VERIFY-THE-BREAK
    Every break is followed by a probe proving the component is genuinely broken.
    A break that silently no-ops would let the remediation "pass" against a healthy
    machine -- a false green, and the failure mode that makes a harness like this
    worthless. A break that cannot be verified aborts the run as BreakFailed.

    EXPECTED OUTCOMES
    Invoke-DefenderDynamicPerformance.ps1 promises: a parseable PerformanceScore
    cached under HKLM\SOFTWARE\AIRWATCH\Extensions\HealthDetection, a CurrentProfile
    derived from it (VeryLow / Low / Mid / High), and Defender's
    ScanAvgCPULoadFactor (20/40/50/75), EnableLowCpuPriority (VeryLow only) and
    DisableCpuThrottleOnIdleScans ($false) matching that profile. It writes nothing
    to DEXRecords, so every break here is ExpectFixed:
      ExpectFixed        -- remediation must repair the component
      ExpectReportedOnly -- (unused) remediation must DETECT and report it only

    The script only re-applies Defender settings when CurrentProfile differs from
    the profile it derives, so every break here also invalidates CurrentProfile
    (removes it or stamps the 'DEXTestBroken' marker). Drift with an intact,
    matching CurrentProfile is NOT repaired by the script and is not broken here;
    see WHAT IS NOT COVERED.

    The expected end state is derived from the PerformanceScore the script leaves
    in the registry, using the same score-to-profile mapping the script uses, so
    the validation holds on any hardware class.

    WHAT IS NOT COVERED, AND WHY
      Silent drift (settings changed, CurrentProfile still equal to the derived
        profile): by design the script skips Set-MpPreference in that case, so
        there is no promised repair to validate against.
      Defender cmdlets unavailable (exit 1): not injectable without uninstalling
        the Defender feature.
      Hardware score inputs (BIOS date, CPU count, disk type): read-only facts of
        the host.

    REBOOTS
    No break in this catalog needs a reboot. The reboot plumbing (-IncludeRebootBreaks,
    -Resume) is retained for parity with the other break tests.

.PARAMETER RemediationTest
    After breaking, run Invoke-DefenderDynamicPerformance.ps1 and validate the outcome.
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

.PARAMETER IncludeRebootBreaks
    Allow breaks that require a reboot to take effect. Default off.

.PARAMETER Restore
    Undo an in-flight run's breaks and exit. No remediation, no validation.

.PARAMETER Resume
    Internal. Used by the AtStartup task to re-enter after a reboot.

.PARAMETER Force
    Required acknowledgement that this machine will be broken.

.NOTES
    Script Name  : Invoke-DefenderDynamicPerformance_BreakTest.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : Administrator (elevated)
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-02
    Reporting    : C:\Temp\FixReport\Invoke-DefenderDynamicPerformance\

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
    [switch]$IncludeRebootBreaks,
    [switch]$Restore,
    [switch]$Resume,
    [switch]$Force,
    [string[]]$ProductionDomainDenyList = @()
)

$ErrorActionPreference = 'Stop'

$ScriptUnderTest   = 'Invoke-DefenderDynamicPerformance'
$RemediationScript = Join-Path $PSScriptRoot '..\Invoke-DefenderDynamicPerformance.ps1'
# Invoke-DefenderDynamicPerformance.ps1 writes no findings to DEXRecords; its only
# registry footprint is the HealthDetection cache below. Kept for schema parity.
$DexRecordsPath    = $null
$SelfPath          = $MyInvocation.MyCommand.Path

$modulePath = Join-Path $PSScriptRoot '..\..\..\AutomatedTesting\DEXTestFramework.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    throw "DEXTestFramework.psm1 not found at $modulePath"
}
Import-Module $modulePath -Force

# -- Fixture ------------------------------------------------------------------
# The cache key the script reads and writes. The breaks mutate values under it;
# the key itself is the script's own and is left in place by Remove-Fixture.
$HealthDetectionPath = 'HKLM:\SOFTWARE\AIRWATCH\Extensions\HealthDetection'
$ValidProfiles       = @('VeryLow', 'Low', 'Mid', 'High')
# 5 is the lowest value Set-MpPreference accepts and no profile maps to it.
$BrokenLoadFactor    = 5
# A profile name the script never writes, so a mismatch is guaranteed.
$BrokenProfileMarker = 'DEXTestBroken'
# A score that [int]::TryParse rejects, forcing the recompute path.
$CorruptScoreMarker  = 'DEXTest-NaN'

function Initialize-Fixture {
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        Import-Module -Name ConfigDefender -SkipEditionCheck -ErrorAction SilentlyContinue
    }
    if (-not (Get-Command Get-MpPreference -ErrorAction SilentlyContinue)) {
        throw 'Microsoft Defender cmdlets are not available on this host; nothing to break.'
    }
    if (-not (Test-Path -LiteralPath $HealthDetectionPath)) {
        New-Item -Path $HealthDetectionPath -Force -ErrorAction Stop | Out-Null
        Write-DexStep -Status 'Info' -Name 'Fixture' -Message "Created '$HealthDetectionPath'"
    }
}

function Remove-Fixture {
    # The remediation script creates HealthDetection itself on first run, so an empty
    # key is baseline-equivalent. Values are restored per break, never deleted here.
}

# -- Helpers ------------------------------------------------------------------

function Get-HealthDetectionValue {
    param([Parameter(Mandatory = $true)][string]$Name)
    $item = Get-ItemProperty -Path $HealthDetectionPath -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $item) { return @{ Exists = $false; Value = $null } }
    @{ Exists = $true; Value = [string]$item.$Name }
}

function Set-HealthDetectionValue {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Value
    )
    if (-not (Test-Path -LiteralPath $HealthDetectionPath)) {
        New-Item -Path $HealthDetectionPath -Force -ErrorAction Stop | Out-Null
    }
    New-ItemProperty -Path $HealthDetectionPath -Name $Name -Value $Value -PropertyType String -Force -ErrorAction Stop | Out-Null
}

function Remove-HealthDetectionValue {
    param([Parameter(Mandatory = $true)][string]$Name)
    if ((Get-HealthDetectionValue -Name $Name).Exists) {
        Remove-ItemProperty -Path $HealthDetectionPath -Name $Name -Force -ErrorAction Stop
    }
}

function Restore-HealthDetectionValue {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$Snapshot
    )
    if ([bool]$Snapshot.Exists) {
        Set-HealthDetectionValue -Name $Name -Value ([string]$Snapshot.Value)
    } else {
        Remove-HealthDetectionValue -Name $Name
    }
}

function Test-ProfileMarkerInvalid {
    # True when CurrentProfile is absent or not one of the four names the script writes.
    $m = Get-HealthDetectionValue -Name CurrentProfile
    (-not $m.Exists) -or ($ValidProfiles -notcontains $m.Value)
}

function Get-DefenderCpuSnapshot {
    $p = Get-MpPreference -ErrorAction Stop
    @{
        ScanAvgCPULoadFactor          = [int]$p.ScanAvgCPULoadFactor
        EnableLowCpuPriority          = [bool]$p.EnableLowCpuPriority
        DisableCpuThrottleOnIdleScans = [bool]$p.DisableCpuThrottleOnIdleScans
    }
}

function Restore-DefenderCpuSnapshot {
    param([Parameter(Mandatory = $true)]$Snapshot)
    Set-MpPreference -ScanAvgCPULoadFactor ([byte]$Snapshot.ScanAvgCPULoadFactor) -ErrorAction SilentlyContinue
    Set-MpPreference -EnableLowCpuPriority ([bool]$Snapshot.EnableLowCpuPriority) -ErrorAction SilentlyContinue
    Set-MpPreference -DisableCpuThrottleOnIdleScans ([bool]$Snapshot.DisableCpuThrottleOnIdleScans) -ErrorAction SilentlyContinue
}

function Get-ExpectedDefenderProfile {
    <#
        Mirrors the score-to-profile mapping in Invoke-DefenderDynamicPerformance.ps1
        from the PerformanceScore currently cached. Returns $null when the cache is
        missing or unparseable, which after remediation is itself a failure.
    #>
    $score  = Get-HealthDetectionValue -Name PerformanceScore
    $parsed = 0
    if (-not $score.Exists) { return $null }
    if (-not [int]::TryParse([string]$score.Value, [ref]$parsed)) { return $null }

    $profile = if     ($parsed -lt 0) { 'VeryLow' }
               elseif ($parsed -le 2) { 'Low' }
               elseif ($parsed -le 6) { 'Mid' }
               else                   { 'High' }
    $factor = switch ($profile) {
        'VeryLow' { 20 }
        'Low'     { 40 }
        'Mid'     { 50 }
        'High'    { 75 }
    }
    @{ Profile = $profile; LoadFactor = $factor; LowCpu = ($profile -eq 'VeryLow') }
}

function Test-DefenderProfileApplied {
    <#
        The whole promise of the script in one probe: a parseable cached score, a
        CurrentProfile derived from it, and Defender preferences matching that profile.
    #>
    $expected = Get-ExpectedDefenderProfile
    if (-not $expected) { return $false }
    $cur    = Get-DefenderCpuSnapshot
    $marker = Get-HealthDetectionValue -Name CurrentProfile
    ($cur.ScanAvgCPULoadFactor -eq $expected.LoadFactor) -and
    ($cur.EnableLowCpuPriority -eq $expected.LowCpu) -and
    (-not $cur.DisableCpuThrottleOnIdleScans) -and
    $marker.Exists -and ($marker.Value -eq $expected.Profile)
}

# -- Break definitions ---------------------------------------------------------
# Capture runs before any mutation; Restore consumes what it returned.
# Verify proves the break landed. Validate decides whether remediation did its job.
# The two breaks can share a run: both touch CurrentProfile, and the harness's
# reverse-order Restore lets the oldest capture (the true baseline) win.
$BreakCatalog = @(

    @{
        Name            = 'CpuProfileDrift'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        Methods         = @(
            @{
                # Load factor pushed off-profile; cache claims a profile the script never writes.
                Name  = 'LoadFactorDriftStaleMarker'
                Apply = {
                    Set-MpPreference -ScanAvgCPULoadFactor ([byte]$BrokenLoadFactor) -ErrorAction Stop
                    Set-HealthDetectionValue -Name CurrentProfile -Value $BrokenProfileMarker
                }
            },
            @{
                # Priority/throttle flags flipped; cache has no profile at all.
                Name  = 'PriorityDriftMarkerRemoved'
                Apply = {
                    Set-MpPreference -EnableLowCpuPriority $true -ErrorAction Stop
                    Set-MpPreference -DisableCpuThrottleOnIdleScans $true -ErrorAction Stop
                    Remove-HealthDetectionValue -Name CurrentProfile
                }
            }
        )
        Capture  = {
            @{
                Defender       = Get-DefenderCpuSnapshot
                CurrentProfile = Get-HealthDetectionValue -Name CurrentProfile
            }
        }
        Verify   = {
            $cur = Get-DefenderCpuSnapshot
            (($cur.ScanAvgCPULoadFactor -eq $BrokenLoadFactor) -or $cur.DisableCpuThrottleOnIdleScans) -and
            (Test-ProfileMarkerInvalid)
        }
        Validate = { Test-DefenderProfileApplied }
        Restore  = {
            param($Original)
            Restore-DefenderCpuSnapshot -Snapshot $Original.Defender
            Restore-HealthDetectionValue -Name CurrentProfile -Snapshot $Original.CurrentProfile
        }
    },

    @{
        Name            = 'ScoreCacheCorrupt'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        Methods         = @(
            @{
                # Unparseable score forces a recompute; the stale marker forces the re-apply.
                Name  = 'NonNumericScore'
                Apply = {
                    Set-HealthDetectionValue -Name PerformanceScore -Value $CorruptScoreMarker
                    Set-HealthDetectionValue -Name CurrentProfile   -Value $BrokenProfileMarker
                }
            },
            @{
                # The first-run path: no cache at all, score computed and profile applied fresh.
                Name  = 'CacheWiped'
                Apply = {
                    Remove-HealthDetectionValue -Name PerformanceScore
                    Remove-HealthDetectionValue -Name CurrentProfile
                }
            }
        )
        Capture  = {
            @{
                Defender         = Get-DefenderCpuSnapshot
                PerformanceScore = Get-HealthDetectionValue -Name PerformanceScore
                CurrentProfile   = Get-HealthDetectionValue -Name CurrentProfile
            }
        }
        Verify   = {
            $s = Get-HealthDetectionValue -Name PerformanceScore
            $n = 0
            (-not $s.Exists) -or (-not [int]::TryParse([string]$s.Value, [ref]$n))
        }
        Validate = { Test-DefenderProfileApplied }
        Restore  = {
            param($Original)
            Restore-HealthDetectionValue -Name PerformanceScore -Snapshot $Original.PerformanceScore
            Restore-HealthDetectionValue -Name CurrentProfile   -Snapshot $Original.CurrentProfile
            Restore-DefenderCpuSnapshot -Snapshot $Original.Defender
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

Write-DexBanner -Title "Invoke-DefenderDynamicPerformance_BreakTest" -Detail "Environment: $Environment"

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
    Remove-Fixture
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

        Initialize-Fixture

        $candidates = if ($BreakName) {
            @($BreakCatalog | Where-Object { $BreakName -contains $_.Name })
        } else {
            @($BreakCatalog | Where-Object { $IncludeRebootBreaks -or -not $_.RequiresReboot })
        }

        if ($candidates.Count -eq 0) { throw 'No break definitions matched the requested selection.' }

        $selected = if ($BreakName) {
            $candidates
        } else {
            Get-DexRandomSubset -InputObject $candidates -Random $state.Random -Count $BreakCount
        }

        # Both breaks can share a run (see the note above $BreakCatalog); no guard needed.

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
            # Commit at once so Restore can undo this break even if a later Capture/Apply throws.
            # On 2026-10-28 a disabled Spooler was left behind because the next break's Capture
            # threw and the applied list had not been committed yet.
            $state.Breaks = $applied
            Save-DexTestState -State $state
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
            $passed = [bool](& $def.Validate)

            $expected = if ($b.ExpectedOutcome -eq 'ExpectFixed') {
                'component repaired by remediation'
            } else {
                'component detected and reported, left unmodified'
            }

            $validation += @{
                Name     = $b.Name
                Expected = $expected
                Actual   = if ($passed) { 'as expected' } else { 'NOT as expected' }
                Result   = if ($passed) { 'Pass' } else { 'Fail' }
            }
            Write-DexStep -Status $(if ($passed) { 'Passed' } else { 'Failed' }) `
                          -Name "Validate $($b.Name)" -Message $expected
        }

        $state.Validation = $validation
        $state.Phase      = 'Validated'

        $failedCount = @($validation | Where-Object { $_.Result -eq 'Fail' }).Count
        $state.Overall = if ($failedCount -eq 0) {
            'Passed'
        } elseif ($state.Remediation -and [int]$state.Remediation.ExitCode -eq 0) {
            # Remediation claimed success while the component is still broken.
            'FalsePass'
        } else {
            'Failed'
        }

        Save-DexTestState -State $state
    }

} catch {
    Write-DexStep -Status 'Failed' -Name 'Harness' -Message $_.Exception.Message
    $state.HarnessError = "$($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
    if ($state.Overall -eq 'Incomplete') { $state.Overall = 'Failed' }
    $exitCode = 1
}

# -- Restore -------------------------------------------------------------------
# Snapshot environments revert on the host, so restoring here would only add risk.
if ($Environment -eq 'Physical') {
    $restoreFailed = $false
    # Restore newest-first. A later break's Capture can record state an earlier break had
    # already changed; undoing in reverse order lets the oldest capture, the true baseline, win.
    $toRestore = @($state.Breaks); [array]::Reverse($toRestore)
    foreach ($b in $toRestore) {
        $def = Get-BreakDefinition -Name $b.Name
        if (-not $def) { continue }
        try {
            & $def.Restore ([PSCustomObject]$b.OriginalState)
        } catch {
            $restoreFailed = $true
            Write-DexStep -Status 'Failed' -Name "Restore $($b.Name)" -Message $_.Exception.Message
        }
    }
    try { Remove-Fixture } catch { $restoreFailed = $true }

    if ($restoreFailed) {
        $state.Overall = 'Dirty'
        Write-DexStep -Status 'Failed' -Name 'Restore' -Message 'machine left modified -- manual cleanup required'
    } else {
        $state.Phase = 'Restored'
        Write-DexStep -Status 'Passed' -Name 'Restore' -Message 'machine returned to baseline'
    }
}

Unregister-DexTestResume -State $state

Write-Output ''
Write-DexStep -Status $(switch ($state.Overall) { 'Passed' { 'Passed' } 'BreakOnly' { 'Info' } default { 'Failed' } }) `
              -Name 'Overall' -Message $state.Overall

Write-DexTestResult -State $state | Out-Null
Clear-DexTestState -State $state

exit $exitCode
