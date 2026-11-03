<#
.SYNOPSIS
    Invoke-AutoRemediateTimeSync_BreakTest -- deliberately stops or disables the
    Windows Time service, or removes the workgroup time source, then verifies
    Invoke-AutoRemediateTimeSync.ps1 repairs or reports it.

.DESCRIPTION
    Break -> verify-the-break -> remediate -> validate -> restore. Writes a uniform
    JSON result to C:\Temp\FixReport\Invoke-AutoRemediateTimeSync\ for
    Invoke-FixReportAnalysis.ps1 to aggregate.

    THIS SCRIPT IS DELIBERATELY DESTRUCTIVE. It stops the W32Time service and changes
    its start type, and on a workgroup host it rewrites the W32Time source
    configuration. Run it only on a disposable VM or a marked test host. See
    Assert-DexTestHost in DEXTestFramework.psm1.

    VERIFY-THE-BREAK
    Every break is followed by a probe proving the component is genuinely broken.
    A break that silently no-ops would let the remediation "pass" against a healthy
    machine -- a false green, and the failure mode that makes a harness like this
    worthless. A break that cannot be verified aborts the run as BreakFailed.

    EXPECTED OUTCOMES
      ExpectFixed        -- remediation must repair the component
      ExpectReportedOnly -- remediation must DETECT and report it, and leave it alone

    W32TimeService      Service stopped and Disabled, or stopped and Manual on a
                        domain member. Step 1 promises a running service with the
                        right start type; validation checks both halves.
    WorkgroupNoPeer     Workgroup hosts only. W32Time Type set to NoSync. Step 2 is
                        report-only on a workgroup device unless ConfigureWorkgroupNtp
                        is set, and the harness runs the script with defaults, so the
                        configuration must be reported and left exactly as broken.
                        Skipped automatically on a domain-joined host.

    The clock itself is never moved. A clock-offset break would need the time source
    reachable to validate, which cannot be guaranteed in a lab, and skewing the
    clock on a shared host interferes with every other test running there.

    REPORTED-ONLY VALIDATION
    The script under test writes per-step values to
    HKLM:\Software\AirWatch\Extension\DEXRecords\SystemHealth\TimeSync as
    StepNN_<Name> = "[Warning] <Name>: ..." plus a LastScanTime. A report-only break
    is validated by that value from a scan that started after this test did, and by
    the step's own "[Warning] <step name>:" line in the captured output.

    REBOOTS
    Nothing here needs a reboot; service and W32Time configuration changes are live
    immediately. The reboot plumbing is kept so the harness stays uniform with its
    siblings, and -IncludeRebootBreaks has no effect here.

.PARAMETER RemediationTest
    After breaking, run Invoke-AutoRemediateTimeSync.ps1 and validate the outcome.
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
    Script Name  : Invoke-AutoRemediateTimeSync_BreakTest.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : Administrator (elevated)
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-03
    Reporting    : C:\Temp\FixReport\Invoke-AutoRemediateTimeSync\

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

$ScriptUnderTest   = 'Invoke-AutoRemediateTimeSync'
$RemediationScript = Join-Path $PSScriptRoot '..\Invoke-AutoRemediateTimeSync.ps1'
$DexRecordsPath    = 'HKLM:\Software\AirWatch\Extension\DEXRecords\SystemHealth\TimeSync'
$W32Params         = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters'
$SelfPath          = $MyInvocation.MyCommand.Path

$modulePath = Join-Path $PSScriptRoot '..\..\..\AutomatedTesting\DEXTestFramework.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    throw "DEXTestFramework.psm1 not found at $modulePath"
}
Import-Module $modulePath -Force

$IsDomainJoined = [bool](Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue).PartOfDomain

# -- Fixture ------------------------------------------------------------------
# No fixture to build: the breaks act on the real W32Time service and configuration
# and Restore puts back what Capture recorded.
function Initialize-Fixture {
    if (-not (Get-Service -Name 'W32Time' -ErrorAction SilentlyContinue)) {
        throw 'The W32Time service is not present; nothing to break.'
    }
}

function Remove-Fixture { }

# -- Helpers ------------------------------------------------------------------

function Write-DexNote {
    # Host-stream diagnostic for use inside Verify/Validate blocks, whose output
    # stream the harness casts to [bool]; Write-DexStep would pollute that stream.
    param([Parameter(Mandatory = $true)][string]$Name, [string]$Message = '')
    Write-Host "  [Info   ] $Name$(if ($Message) { ": $Message" })" -ForegroundColor Gray
}

function Get-DexW32Service {
    Get-Service -Name 'W32Time' -ErrorAction Stop
}

function Get-DexW32Type {
    [string](Get-ItemProperty -Path $W32Params -Name 'Type' -ErrorAction SilentlyContinue).Type
}

function Set-DexW32Type {
    param([Parameter(Mandatory = $true)][string]$Type)
    Set-ItemProperty -Path $W32Params -Name 'Type' -Value $Type -Type String -ErrorAction Stop
    # The service reads its configuration at start; a restart makes the change live.
    & w32tm.exe /config /update 2>&1 | Out-Null
    Restart-Service -Name 'W32Time' -ErrorAction SilentlyContinue
}

function Test-DexStepReported {
    <#
        Confirms the remediation reported a finding for a report-only step: the
        step's DEXRecords value from a scan newer than this test, and the step's
        own [Warning] line in the captured console output.
    #>
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
        # and never matches the literal tag (run 3042d520cb84, 2026-11-03).
        $prefix  = "[Warning] $StepName"
        $stepVal = ($key.PSObject.Properties | Where-Object { $_.Name -like 'Step*' -and ([string]$_.Value).StartsWith($prefix) } | Select-Object -First 1)
        $regOk   = $key -and $stepVal -and $lastScan -and ($lastScan -ge $started.AddMinutes(-1))
    }

    return ($outputOk -and $regOk)
}

# -- Break definitions ---------------------------------------------------------
# Capture runs before any mutation; Restore consumes what it returned.
# Verify proves the break landed. Validate decides whether remediation did its job.
$BreakCatalog = @(

    @{
        # Step 1: W32Time Service. Stopped and Disabled is the primary case; stopped
        # and Manual only counts as broken on a domain member (workgroup devices run
        # it from a trigger, and the script accepts Manual there).
        Name            = 'W32TimeService'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        Methods         = @(
            @{
                Name  = 'StoppedDisabled'
                Apply = {
                    Stop-Service -Name 'W32Time' -Force -ErrorAction Stop
                    Set-Service  -Name 'W32Time' -StartupType Disabled -ErrorAction Stop
                }
            },
            @{
                Name  = 'StoppedManualOrDisabled'
                Apply = {
                    Stop-Service -Name 'W32Time' -Force -ErrorAction Stop
                    # Manual is only a fault on a domain member; a workgroup host gets Disabled.
                    $type = if ($IsDomainJoined) { 'Manual' } else { 'Disabled' }
                    Set-Service -Name 'W32Time' -StartupType $type -ErrorAction Stop
                }
            }
        )
        Capture  = {
            $s = Get-DexW32Service
            @{ Status = [string]$s.Status; StartType = [string]$s.StartType }
        }
        Verify   = {
            $s = Get-DexW32Service
            Write-DexNote -Name 'Verify W32TimeService' -Message "status=$($s.Status) startType=$($s.StartType)"
            ($s.Status -ne 'Running') -and ($s.StartType -eq 'Disabled' -or ($IsDomainJoined -and $s.StartType -ne 'Automatic'))
        }
        # Step 1 promises a running service with Automatic on a domain member and
        # anything but Disabled on a workgroup host.
        Validate = {
            $s = Get-DexW32Service
            Write-DexNote -Name 'Validate W32TimeService' -Message "status=$($s.Status) startType=$($s.StartType)"
            ($s.Status -eq 'Running') -and ($s.StartType -ne 'Disabled') -and (-not $IsDomainJoined -or $s.StartType -eq 'Automatic')
        }
        Restore  = {
            param($Original)
            if ($Original.StartType) { Set-Service -Name 'W32Time' -StartupType $Original.StartType -ErrorAction SilentlyContinue }
            if ($Original.Status -eq 'Running') { Start-Service -Name 'W32Time' -ErrorAction SilentlyContinue }
            else { Stop-Service -Name 'W32Time' -Force -ErrorAction SilentlyContinue }
        }
    },

    @{
        # Step 2: Time Source Configuration. On a workgroup host the script reports a
        # missing peer and changes nothing unless ConfigureWorkgroupNtp is set. The
        # harness runs it with defaults, so this is a report-only expectation.
        Name            = 'WorkgroupNoPeer'
        ExpectedOutcome = 'ExpectReportedOnly'
        RequiresReboot  = $false
        Methods         = @(
            @{
                Name  = 'TypeNoSync'
                Apply = {
                    if ($IsDomainJoined) { throw 'WorkgroupNoPeer applies to workgroup hosts only; this host is domain joined.' }
                    Set-DexW32Type -Type 'NoSync'
                }
            }
        )
        Capture  = { @{ Type = (Get-DexW32Type) } }
        Verify   = {
            $t = Get-DexW32Type
            Write-DexNote -Name 'Verify WorkgroupNoPeer' -Message "Type=$t"
            $t -eq 'NoSync'
        }
        # Correct behaviour is to report and leave alone: Type must still be NoSync
        # and the finding must have been recorded.
        Validate = {
            $t        = Get-DexW32Type
            $reported = Test-DexStepReported -StepName 'Time Source Configuration'
            Write-DexNote -Name 'Validate WorkgroupNoPeer' -Message "Type=$t reported=$reported"
            ($t -eq 'NoSync') -and $reported
        }
        Restore  = {
            param($Original)
            if ($Original.Type) { Set-DexW32Type -Type $Original.Type }
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

Write-DexBanner -Title "Invoke-AutoRemediateTimeSync_BreakTest" -Detail "Environment: $Environment  DomainJoined: $IsDomainJoined"

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

        # The workgroup break has no meaning on a domain member.
        if ($IsDomainJoined) {
            $candidates = @($candidates | Where-Object { $_.Name -ne 'WorkgroupNoPeer' })
        }

        if ($candidates.Count -eq 0) { throw 'No break definitions matched the requested selection.' }

        $selected = if ($BreakName) {
            $candidates
        } else {
            Get-DexRandomSubset -InputObject $candidates -Random $state.Random -Count $BreakCount
        }

        # Both breaks can share a run: the service break is validated on service state
        # and the configuration break on the Type value, and the script's step 1 does
        # not require the service to be running on a workgroup host with NoSync.

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
