<#
.SYNOPSIS
    Invoke-AutoRemediateCertEnrollment_BreakTest -- deliberately disables the
    certificate autoenrollment task, or plants an expired or weakly signed
    self-signed test certificate, then verifies Invoke-AutoRemediateCertEnrollment.ps1
    repairs or reports it.

.DESCRIPTION
    Break -> verify-the-break -> remediate -> validate -> restore. Writes a uniform
    JSON result to C:\Temp\FixReport\Invoke-AutoRemediateCertEnrollment\ for
    Invoke-FixReportAnalysis.ps1 to aggregate.

    THIS SCRIPT IS DELIBERATELY DESTRUCTIVE. It disables a CertificateServicesClient
    scheduled task and adds self-signed test certificates to LocalMachine\My (subject
    "CN=DEXTest ..."), which Restore removes by thumbprint. Run it only on a
    disposable VM or a marked test host. See Assert-DexTestHost in DEXTestFramework.psm1.

    VERIFY-THE-BREAK
    Every break is followed by a probe proving the component is genuinely broken.
    A break that silently no-ops would let the remediation "pass" against a healthy
    machine -- a false green, and the failure mode that makes a harness like this
    worthless. A break that cannot be verified aborts the run as BreakFailed.

    EXPECTED OUTCOMES
      ExpectFixed        -- remediation must repair the component
      ExpectReportedOnly -- remediation must DETECT and report it, and leave it alone

    AutoenrollmentTask      A CertificateServicesClient task disabled. Step 1
                            promises to re-enable it.
    ExpiredCertificate      An already-expired self-signed certificate in
                            LocalMachine\My. It carries no AD CS template extension,
                            so step 2 must report it and must not delete it.
    WeakAlgorithmCertificate A valid SHA-1 signed self-signed certificate in
                            LocalMachine\My. Step 3 is report-only.

    REPORTED-ONLY VALIDATION
    The script under test writes per-step values to
    HKLM:\Software\AirWatch\Extension\DEXRecords\SystemHealth\CertEnrollment as
    StepNN_<Name> = "[Warning] <Name>: ..." plus a LastScanTime. A report-only break
    is validated by that value from a scan that started after this test did, by the
    step's own "[Warning] <step name>:" line in the captured output, and by the
    fixture certificate still being present.

    REBOOTS
    Nothing here needs a reboot. The reboot plumbing is kept so the harness stays
    uniform with its siblings, and -IncludeRebootBreaks has no effect here.

.PARAMETER RemediationTest
    After breaking, run Invoke-AutoRemediateCertEnrollment.ps1 and validate the
    outcome. Without this the script breaks and reports only.

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
    Script Name  : Invoke-AutoRemediateCertEnrollment_BreakTest.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : Administrator (elevated)
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-03
    Reporting    : C:\Temp\FixReport\Invoke-AutoRemediateCertEnrollment\

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

$ScriptUnderTest   = 'Invoke-AutoRemediateCertEnrollment'
$RemediationScript = Join-Path $PSScriptRoot '..\Invoke-AutoRemediateCertEnrollment.ps1'
$DexRecordsPath    = 'HKLM:\Software\AirWatch\Extension\DEXRecords\SystemHealth\CertEnrollment'
$AeTaskPath        = '\Microsoft\Windows\CertificateServicesClient\'
$SelfPath          = $MyInvocation.MyCommand.Path

$modulePath = Join-Path $PSScriptRoot '..\..\..\AutomatedTesting\DEXTestFramework.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    throw "DEXTestFramework.psm1 not found at $modulePath"
}
Import-Module $modulePath -Force

# -- Fixture ------------------------------------------------------------------
# Fixture certificates are self-signed, carry a DEXTest subject, and are removed by
# thumbprint. Nothing that was in the store before the run is ever touched.
$FixtureExpiredSubject = 'CN=DEXTest Expired Machine Cert'
$FixtureWeakSubject    = 'CN=DEXTest SHA1 Machine Cert'

function Initialize-Fixture {
    if (-not (Get-Command -Name New-SelfSignedCertificate -ErrorAction SilentlyContinue)) {
        throw 'New-SelfSignedCertificate is not available; cannot build the test fixture.'
    }
}

function Remove-Fixture {
    Get-ChildItem -Path 'Cert:\LocalMachine\My' -ErrorAction SilentlyContinue |
        Where-Object { $_.Subject -like 'CN=DEXTest *' } |
        ForEach-Object { Remove-Item -LiteralPath "Cert:\LocalMachine\My\$($_.Thumbprint)" -Force -ErrorAction SilentlyContinue }
}

# -- Helpers ------------------------------------------------------------------

function Write-DexNote {
    param([Parameter(Mandatory = $true)][string]$Name, [string]$Message = '')
    Write-Host "  [Info   ] $Name$(if ($Message) { ": $Message" })" -ForegroundColor Gray
}

function Get-DexAeTask {
    # The user-context task exists on every build; the machine task only on some.
    $tasks = @(Get-ScheduledTask -TaskPath $AeTaskPath -ErrorAction SilentlyContinue)
    $pick  = $tasks | Where-Object { $_.TaskName -eq 'SystemTask' } | Select-Object -First 1
    if (-not $pick) { $pick = $tasks | Where-Object { $_.TaskName -eq 'UserTask' } | Select-Object -First 1 }
    return $pick
}

function Get-DexFixtureCert {
    param([Parameter(Mandatory = $true)][string]$Subject)
    Get-ChildItem -Path 'Cert:\LocalMachine\My' -ErrorAction SilentlyContinue |
        Where-Object { $_.Subject -eq $Subject } | Select-Object -First 1
}

function Remove-DexFixtureCert {
    param([Parameter(Mandatory = $true)][string]$Subject)
    Get-ChildItem -Path 'Cert:\LocalMachine\My' -ErrorAction SilentlyContinue |
        Where-Object { $_.Subject -eq $Subject } |
        ForEach-Object { Remove-Item -LiteralPath "Cert:\LocalMachine\My\$($_.Thumbprint)" -Force -ErrorAction SilentlyContinue }
}

function Test-DexStepReported {
    param([Parameter(Mandatory = $true)][string]$StepName)

    $outputOk = $false
    if ($state -and $state.Remediation -and $state.Remediation.Output) {
        $pattern  = '\[Warning\]\s+' + [regex]::Escape($StepName) + ':'
        $outputOk = ([string]$state.Remediation.Output) -match $pattern
    }

    $regOk = $false
    if (Test-Path -LiteralPath $DexRecordsPath) {
        $key = Get-ItemProperty -LiteralPath $DexRecordsPath -ErrorAction SilentlyContinue
        $lastScan = $null
        if ($key -and $key.LastScanTime) {
            try { $lastScan = [datetime]::ParseExact([string]$key.LastScanTime, 'yyyy-MM-dd HH:mm:ss', $null) } catch { $lastScan = $null }
        }
        $started = [datetime]::Parse([string]$state.StartedAt)
        # StartsWith, not -like: in a wildcard pattern "[Warning]" is a character class
        # and never matches the literal tag (run a509cfb91722, 2026-11-03).
        $prefix  = "[Warning] $StepName"
        $stepVal = ($key.PSObject.Properties | Where-Object { $_.Name -like 'Step*' -and ([string]$_.Value).StartsWith($prefix) } | Select-Object -First 1)
        $regOk   = $key -and $stepVal -and $lastScan -and ($lastScan -ge $started.AddMinutes(-1))
    }

    return ($outputOk -and $regOk)
}

# -- Break definitions ---------------------------------------------------------
$BreakCatalog = @(

    @{
        # Step 1: Autoenrollment Tasks. A disabled CertificateServicesClient task
        # must be re-enabled.
        Name            = 'AutoenrollmentTask'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        Methods         = @(
            @{
                Name  = 'DisableTask'
                Apply = {
                    $t = Get-DexAeTask
                    if (-not $t) { throw 'No CertificateServicesClient task found to disable.' }
                    Disable-ScheduledTask -TaskPath $t.TaskPath -TaskName $t.TaskName -ErrorAction Stop | Out-Null
                }
            }
        )
        Capture  = {
            $t = Get-DexAeTask
            @{ TaskName = $(if ($t) { $t.TaskName } else { '' }); State = $(if ($t) { [string]$t.State } else { '' }) }
        }
        Verify   = {
            $t = Get-DexAeTask
            Write-DexNote -Name 'Verify AutoenrollmentTask' -Message "task=$($t.TaskName) state=$($t.State)"
            $t -and ($t.State -eq 'Disabled')
        }
        Validate = {
            $t = Get-DexAeTask
            Write-DexNote -Name 'Validate AutoenrollmentTask' -Message "task=$($t.TaskName) state=$($t.State)"
            $t -and ($t.State -ne 'Disabled')
        }
        Restore  = {
            param($Original)
            if ($Original.TaskName -and $Original.State -and $Original.State -ne 'Disabled') {
                Enable-ScheduledTask -TaskPath $AeTaskPath -TaskName $Original.TaskName -ErrorAction SilentlyContinue | Out-Null
            }
        }
    },

    @{
        # Step 2: Machine Certificate Expiry. A non-AD CS certificate that has
        # expired is reported with its subject and left in the store.
        Name            = 'ExpiredCertificate'
        ExpectedOutcome = 'ExpectReportedOnly'
        RequiresReboot  = $false
        Methods         = @(
            @{
                Name  = 'ExpiredSelfSigned'
                Apply = {
                    New-SelfSignedCertificate -Subject $FixtureExpiredSubject -CertStoreLocation 'Cert:\LocalMachine\My' `
                        -NotBefore (Get-Date).AddYears(-2) -NotAfter (Get-Date).AddDays(-2) `
                        -KeyExportPolicy NonExportable -ErrorAction Stop | Out-Null
                }
            }
        )
        Capture  = { @{ Existed = [bool](Get-DexFixtureCert -Subject $FixtureExpiredSubject) } }
        Verify   = {
            $c = Get-DexFixtureCert -Subject $FixtureExpiredSubject
            Write-DexNote -Name 'Verify ExpiredCertificate' -Message "present=$([bool]$c) notAfter=$($c.NotAfter)"
            $c -and ($c.NotAfter -lt (Get-Date))
        }
        Validate = {
            $c        = Get-DexFixtureCert -Subject $FixtureExpiredSubject
            $reported = Test-DexStepReported -StepName 'Machine Certificate Expiry'
            Write-DexNote -Name 'Validate ExpiredCertificate' -Message "stillPresent=$([bool]$c) reported=$reported"
            [bool]$c -and $reported
        }
        Restore  = {
            param($Original)
            Remove-DexFixtureCert -Subject $FixtureExpiredSubject
        }
    },

    @{
        # Step 3: Weak Signature Algorithms. A valid SHA-1 signed certificate is
        # reported and left in place.
        Name            = 'WeakAlgorithmCertificate'
        ExpectedOutcome = 'ExpectReportedOnly'
        RequiresReboot  = $false
        Methods         = @(
            @{
                Name  = 'Sha1SelfSigned'
                Apply = {
                    New-SelfSignedCertificate -Subject $FixtureWeakSubject -CertStoreLocation 'Cert:\LocalMachine\My' `
                        -HashAlgorithm SHA1 -NotAfter (Get-Date).AddYears(1) `
                        -KeyExportPolicy NonExportable -ErrorAction Stop | Out-Null
                }
            }
        )
        Capture  = { @{ Existed = [bool](Get-DexFixtureCert -Subject $FixtureWeakSubject) } }
        Verify   = {
            $c = Get-DexFixtureCert -Subject $FixtureWeakSubject
            Write-DexNote -Name 'Verify WeakAlgorithmCertificate' -Message "present=$([bool]$c) alg=$($c.SignatureAlgorithm.FriendlyName)"
            $c -and ($c.SignatureAlgorithm.FriendlyName -match 'sha1')
        }
        Validate = {
            $c        = Get-DexFixtureCert -Subject $FixtureWeakSubject
            $reported = Test-DexStepReported -StepName 'Weak Signature Algorithms'
            Write-DexNote -Name 'Validate WeakAlgorithmCertificate' -Message "stillPresent=$([bool]$c) reported=$reported"
            [bool]$c -and $reported
        }
        Restore  = {
            param($Original)
            Remove-DexFixtureCert -Subject $FixtureWeakSubject
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

Write-DexBanner -Title "Invoke-AutoRemediateCertEnrollment_BreakTest" -Detail "Environment: $Environment"

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

        # All three breaks act on distinct objects and can share a run.

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
if ($Environment -eq 'Physical') {
    $restoreFailed = $false
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
