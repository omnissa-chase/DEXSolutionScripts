<#
.SYNOPSIS
    Invoke-RemediatePageFile_BreakTest -- deliberately takes the page file out of
    automatic management, then verifies Invoke-RemediatePageFile.ps1 reports or
    repairs it as designed.

.DESCRIPTION
    Break -> verify-the-break -> remediate -> validate -> restore. Writes a uniform
    JSON result to C:\Temp\FixReport\Invoke-RemediatePageFile\ for
    Invoke-FixReportAnalysis.ps1 to aggregate.

    THIS SCRIPT IS DELIBERATELY DESTRUCTIVE. It clears Win32_ComputerSystem
    .AutomaticManagedPagefile, writes a fixed-size Win32_PageFileSetting for the
    system drive, and (for one break) sets the machine-scope environment variable
    PageFileUsageFailPercent. Run it only on a disposable VM or a marked test host.
    See Assert-DexTestHost in DEXTestFramework.psm1.

    VERIFY-THE-BREAK
    Every break is followed by a probe proving the component is genuinely broken.
    A break that silently no-ops would let the remediation "pass" against a healthy
    machine -- a false green, and the failure mode that makes a harness like this
    worthless. A break that cannot be verified aborts the run as BreakFailed.

    EXPECTED OUTCOMES
    Invoke-RemediatePageFile.ps1 only repairs a page file that is BOTH manually
    configured AND at or above PageFileUsageFailPercent (default 80). A manual page
    file below the threshold is advisory (Warning, no change). Each break declares
    which it is:
      ExpectFixed        -- remediation must repair the component
      ExpectReportedOnly -- remediation must DETECT and report it, and leave it alone

    PageFileManualUnderThreshold  ExpectReportedOnly. Page file manual, usage low.
                                  Validate: still manual, DEXRecords Status = 'Warning'.
    PageFileManualNearCapacity    ExpectFixed. Page file manual, and the script's own
                                  documented override ($env:PageFileUsageFailPercent)
                                  is set to 0 so the live usage figure counts as "near
                                  capacity". Filling a real page file to 80% is neither
                                  deterministic nor safe on a lab VM, so the threshold
                                  is lowered instead of the usage being raised. The
                                  override is written at Machine scope (so a SYSTEM
                                  resume task inherits it) and in this process (so the
                                  child powershell.exe inherits it). Validate: automatic
                                  management restored, DEXRecords Status = 'Remediated'.
    The two breaks cannot share a run: the lowered threshold would turn the advisory
    case into a repair. When both are selected the one drawn first is kept.

    Not covered: the system-managed-but-high-usage Warning (no reversible way to
    inflate real page-file usage) and the detection-exception branch.

    REBOOTS
    Nothing here is flagged RequiresReboot. The script under test reads the page
    file CONFIGURATION (AutomaticManagedPagefile), which changes immediately, and
    Win32_PageFileUsage, which keeps describing the page file that is currently
    mounted. The break, the remediation and the restore only ever change the
    configuration; the file on disk is resized at the next boot, which is also why
    the script writes RebootRequired = True when it remediates.
    Breaks flagged RequiresReboot would suspend the run, register an AtStartup resume
    task, and reboot. Opt in with -IncludeRebootBreaks; they are excluded by default.

.PARAMETER RemediationTest
    After breaking, run Invoke-RemediatePageFile.ps1 and validate the outcome.
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
    Script Name  : Invoke-RemediatePageFile_BreakTest.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : Administrator (elevated)
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-02
    Reporting    : C:\Temp\FixReport\Invoke-RemediatePageFile\

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

$ScriptUnderTest   = 'Invoke-RemediatePageFile'
$RemediationScript = Join-Path $PSScriptRoot '..\Invoke-RemediatePageFile.ps1'
$DexRecordsPath    = 'HKLM:\Software\AirWatch\Extension\DEXRecords\MemoryErrors\PageFile'
$SelfPath          = $MyInvocation.MyCommand.Path

$modulePath = Join-Path $PSScriptRoot '..\..\..\AutomatedTesting\DEXTestFramework.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    throw "DEXTestFramework.psm1 not found at $modulePath"
}
Import-Module $modulePath -Force

# -- Fixture ------------------------------------------------------------------
# The page file under test is the system drive's own; nothing is built. The
# fixture clears the script's DEXRecords key so a 'Status' value found during
# validation was written by THIS run rather than left over from an earlier one.
# The record written by the run is kept as evidence.
$FixedPageFileMB   = 2048                     # fixed size written by the FixedSize method
$ThresholdEnvName  = 'PageFileUsageFailPercent'
$DefaultThreshold  = 80                       # mirrors the script's default

function Initialize-Fixture {
    if (Test-Path -LiteralPath $DexRecordsPath) {
        Remove-Item -LiteralPath $DexRecordsPath -Recurse -Force -ErrorAction SilentlyContinue
        Write-DexStep -Status 'Info' -Name 'Fixture' -Message "Cleared stale DEXRecords at $DexRecordsPath"
    }
}

function Remove-Fixture {
    # Intentionally empty: the DEXRecords key written by the remediation is left in
    # place so the operator can inspect what the script reported.
}

# -- Helpers ------------------------------------------------------------------

function Get-PageFileComputerSystem {
    Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
}

function Get-PageFileAutomatic {
    [bool](Get-PageFileComputerSystem).AutomaticManagedPagefile
}

function Get-PageFileSettings {
    # Empty while AutomaticManagedPagefile is on; populated once it is cleared.
    @(Get-CimInstance -ClassName Win32_PageFileSetting -ErrorAction SilentlyContinue)
}

function Get-PageFilePeakUsagePercent {
    # Same arithmetic as the script under test, so Verify predicts its branch exactly.
    $maxPct = 0
    foreach ($pf in @(Get-CimInstance -ClassName Win32_PageFileUsage -ErrorAction SilentlyContinue)) {
        if ($pf.AllocatedBaseSize -gt 0) {
            $pct = [math]::Round(($pf.CurrentUsage / $pf.AllocatedBaseSize) * 100, 1)
            if ($pct -gt $maxPct) { $maxPct = $pct }
        }
    }
    $maxPct
}

function Get-EffectiveThreshold {
    # What the script will use when the harness launches it: the process-scope
    # override if one exists, else the script's default.
    $raw = [Environment]::GetEnvironmentVariable($ThresholdEnvName, 'Process')
    if ($raw) { [int]$raw } else { $DefaultThreshold }
}

function Set-PageFileAutomatic {
    param([Parameter(Mandatory = $true)][bool]$Enabled)
    Get-PageFileComputerSystem | Set-CimInstance -Property @{ AutomaticManagedPagefile = $Enabled } -ErrorAction Stop
}

$MemoryManagementKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'

function Get-PagingFilesRegistry {
    # The PagingFiles multi-string that Win32_PageFileSetting is a view of.
    @((Get-ItemProperty -LiteralPath $MemoryManagementKey -Name 'PagingFiles' -ErrorAction SilentlyContinue).PagingFiles)
}

function Set-PagingFilesRegistry {
    param([Parameter(Mandatory = $true)][string[]]$Value)
    Set-ItemProperty -LiteralPath $MemoryManagementKey -Name 'PagingFiles' -Value ([string[]]$Value) -Type MultiString -ErrorAction Stop
}

function Set-PageFileFixedSize {
    <#
        Clears automatic management, then pins the system-drive page file to a
        fixed Initial = Maximum size. Win32_PageFileSetting may be empty right after
        the flag is cleared, in which case the setting is created.

        Every WMI route to the sizes -- Set-CimInstance, New-CimInstance,
        Set-WmiInstance and the object's own Put() -- answered "Value out of range"
        for 2048/2048 on the lab VM (runs 4e166254f72d, 70ec5b19ade0, c845854c3e7e,
        5e9fa8a3e6c3, 2026-11-02) with 9 GB free and 8 GB of RAM. The class is only a
        view of the PagingFiles registry value, so when WMI refuses, that value is
        written directly. Either way the new size applies at the next boot; the
        script under test reads the AutomaticManagedPagefile flag and the live
        Win32_PageFileUsage figures, neither of which depends on the size taking hold.
    #>
    param([Parameter(Mandatory = $true)][int]$SizeMB)

    Set-PageFileAutomatic -Enabled $false
    $name     = Join-Path $env:SystemDrive 'pagefile.sys'
    $existing = Get-PageFileSettings | Where-Object { $_.Name -ieq $name } | Select-Object -First 1
    try {
        if ($existing) {
            $wmi = Get-WmiObject -Class Win32_PageFileSetting -ErrorAction Stop | Where-Object { $_.Name -ieq $name } | Select-Object -First 1
            $wmi.InitialSize = [uint32]$SizeMB
            $wmi.MaximumSize = [uint32]$SizeMB
            $wmi.Put() | Out-Null
        } else {
            New-PageFileSetting -Name $name -SizeMB $SizeMB
        }
    } catch {
        Write-Host "  [Info   ] Fixture: WMI refused the page-file size ($($_.Exception.Message.Trim())); writing the PagingFiles registry value instead" -ForegroundColor Gray
        Set-PagingFilesRegistry -Value @("$name $SizeMB $SizeMB")
    }

    $check = Get-PageFileSettings | Where-Object { $_.Name -ieq $name } | Select-Object -First 1
    if (-not $check -or [int]$check.InitialSize -ne $SizeMB -or [int]$check.MaximumSize -ne $SizeMB) {
        throw "The fixed page-file size did not take: Win32_PageFileSetting shows Initial=$($check.InitialSize) Maximum=$($check.MaximumSize), PagingFiles='$((Get-PagingFilesRegistry) -join '; ')'"
    }
}

function New-PageFileSetting {
    <#
        Creates the Win32_PageFileSetting instance. New-CimInstance on this class fails
        with "Value out of range" (seen on the lab VM, 2026-11-02, run 70ec5b19ade0);
        the WMI provider path accepts the same arguments. If even that refuses the
        sizes, create the instance by name alone and size it afterwards.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][int]$SizeMB
    )
    try {
        Set-WmiInstance -Class Win32_PageFileSetting `
            -Arguments @{ Name = $Name; InitialSize = [uint32]$SizeMB; MaximumSize = [uint32]$SizeMB } `
            -ErrorAction Stop | Out-Null
    } catch {
        Set-WmiInstance -Class Win32_PageFileSetting -Arguments @{ Name = $Name } -ErrorAction Stop | Out-Null
        $created = Get-PageFileSettings | Where-Object { $_.Name -ieq $Name } | Select-Object -First 1
        if (-not $created) { throw "Win32_PageFileSetting '$Name' was not created: $($_.Exception.Message)" }
        $created = Get-WmiObject -Class Win32_PageFileSetting -ErrorAction Stop | Where-Object { $_.Name -ieq $Name } | Select-Object -First 1
        $created.InitialSize = [uint32]$SizeMB; $created.MaximumSize = [uint32]$SizeMB; $created.Put() | Out-Null
    }
}

function Get-PageFileBaseline {
    # Shared Capture body for both breaks. PagingFiles is the raw registry value,
    # kept so Restore can put back exactly what was there (and so the result file
    # records what the host looked like before the break).
    @{
        Automatic   = (Get-PageFileAutomatic)
        PagingFiles = @(Get-PagingFilesRegistry)
        Settings    = @(Get-PageFileSettings | ForEach-Object {
            @{ Name = $_.Name; InitialSize = [int]$_.InitialSize; MaximumSize = [int]$_.MaximumSize }
        })
    }
}

function Restore-PageFileBaseline {
    <#
        Shared Restore body. $Original may be a hashtable (same-process restore) or
        a PSCustomObject rebuilt from state.json (post-reboot or -Restore mode);
        property access works on both.
    #>
    param($Original)

    $raw = @([string[]]@($Original.PagingFiles) | Where-Object { $_ })
    if ($raw.Count -gt 0) {
        # Verbatim registry restore first; the flag write below then either leaves
        # it (manual) or supersedes it (automatic rewrites PagingFiles itself).
        try { Set-PagingFilesRegistry -Value $raw } catch { }
    }

    if ([bool]$Original.Automatic) {
        # Turning automatic management back on makes Windows rewrite PagingFiles
        # itself; any fixed sizes written by the break are superseded.
        Set-PageFileAutomatic -Enabled $true
        return
    }

    Set-PageFileAutomatic -Enabled $false
    if ($raw.Count -gt 0) { return }
    foreach ($s in @($Original.Settings)) {
        if (-not $s) { continue }
        $existing = Get-PageFileSettings | Where-Object { $_.Name -ieq $s.Name } | Select-Object -First 1
        $props    = @{ InitialSize = [uint32]$s.InitialSize; MaximumSize = [uint32]$s.MaximumSize }
        if ($existing) {
            try {
                $wmi = Get-WmiObject -Class Win32_PageFileSetting -ErrorAction Stop | Where-Object { $_.Name -ieq $s.Name } | Select-Object -First 1
                $wmi.InitialSize = [uint32]$s.InitialSize; $wmi.MaximumSize = [uint32]$s.MaximumSize; $wmi.Put() | Out-Null
            } catch { }
        } else {
            try { New-PageFileSetting -Name $s.Name -SizeMB ([int]$s.InitialSize) } catch { }
        }
    }
}

function Test-DexRecordContains {
    <#
        Confirms the remediation script reported a finding for a given step. Used
        by ExpectReportedOnly breaks, where the correct behaviour is to surface the
        problem rather than fix it.
    #>
    param([Parameter(Mandatory = $true)][string]$ValueNamePrefix)

    if (-not (Test-Path -LiteralPath $DexRecordsPath)) { return $false }
    $key = Get-Item -LiteralPath $DexRecordsPath -ErrorAction SilentlyContinue
    if (-not $key) { return $false }
    return @($key.GetValueNames() | Where-Object { $_ -like "$ValueNamePrefix*" }).Count -gt 0
}

function Get-DexRecordValue {
    param([Parameter(Mandatory = $true)][string]$Name)

    if (-not (Test-Path -LiteralPath $DexRecordsPath)) { return $null }
    (Get-ItemProperty -LiteralPath $DexRecordsPath -Name $Name -ErrorAction SilentlyContinue).$Name
}

function Test-DexRecordStatus {
    <#
        The script writes a single 'Status' value per run: Passed, Warning, Failed or
        Remediated. ExpectReportedOnly demands 'Warning'; ExpectFixed demands
        'Remediated'.
    #>
    param([Parameter(Mandatory = $true)][string]$Expected)

    (Test-DexRecordContains -ValueNamePrefix 'Status') -and ((Get-DexRecordValue -Name 'Status') -eq $Expected)
}

# -- Break definitions ---------------------------------------------------------
# Capture runs before any mutation; Restore consumes what it returned.
# Verify proves the break landed. Validate decides whether remediation did its job.
$BreakCatalog = @(

    @{
        Name            = 'PageFileManualUnderThreshold'
        ExpectedOutcome = 'ExpectReportedOnly'
        RequiresReboot  = $false
        Methods         = @(
            @{
                # Windows' "Custom size" radio button: manual, Initial = Maximum.
                Name  = 'FixedSize'
                Apply = { Set-PageFileFixedSize -SizeMB $FixedPageFileMB }
            },
            @{
                # Windows' "System managed size" radio button with the "Automatically
                # manage" checkbox cleared: still manual as far as the script is concerned.
                Name  = 'ClearAutomaticFlagOnly'
                Apply = { Set-PageFileAutomatic -Enabled $false }
            }
        )
        Capture  = { Get-PageFileBaseline }
        # The break only counts if the script will land in its Warning branch: manual
        # AND below threshold. A busy host above threshold would make it a repair.
        Verify   = {
            (-not (Get-PageFileAutomatic)) -and ((Get-PageFilePeakUsagePercent) -lt (Get-EffectiveThreshold))
        }
        # Correct behaviour is to report and leave alone: the page file must still be
        # manual afterwards, and the finding must have reached the registry as Warning.
        Validate = {
            $stillManual = -not (Get-PageFileAutomatic)
            $reported    = Test-DexRecordStatus -Expected 'Warning'
            $stillManual -and $reported
        }
        Restore  = {
            param($Original)
            Restore-PageFileBaseline -Original $Original
        }
    },

    @{
        Name            = 'PageFileManualNearCapacity'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        Methods         = @(
            @{
                Name  = 'FixedSizeWithZeroThreshold'
                Apply = {
                    Set-PageFileFixedSize -SizeMB $FixedPageFileMB
                    # '0' is a non-empty string, so the script's `if ($env:...)` guard
                    # accepts it, and any usage figure satisfies `-ge 0`.
                    [Environment]::SetEnvironmentVariable($ThresholdEnvName, '0', 'Machine')
                    [Environment]::SetEnvironmentVariable($ThresholdEnvName, '0', 'Process')
                }
            }
        )
        Capture  = {
            $base = Get-PageFileBaseline
            $base['ThresholdMachine'] = [Environment]::GetEnvironmentVariable($ThresholdEnvName, 'Machine')
            $base['ThresholdProcess'] = [Environment]::GetEnvironmentVariable($ThresholdEnvName, 'Process')
            $base
        }
        Verify   = {
            (-not (Get-PageFileAutomatic)) -and
            ([Environment]::GetEnvironmentVariable($ThresholdEnvName, 'Machine') -eq '0') -and
            ([Environment]::GetEnvironmentVariable($ThresholdEnvName, 'Process') -eq '0') -and
            ((Get-PageFilePeakUsagePercent) -ge 0)
        }
        Validate = { (Get-PageFileAutomatic) -and (Test-DexRecordStatus -Expected 'Remediated') }
        Restore  = {
            param($Original)
            # Null restores remove the variable; SetEnvironmentVariable(name, $null) deletes.
            $m = $Original.ThresholdMachine; if ([string]::IsNullOrEmpty($m)) { $m = $null }
            $p = $Original.ThresholdProcess; if ([string]::IsNullOrEmpty($p)) { $p = $null }
            [Environment]::SetEnvironmentVariable($ThresholdEnvName, $m, 'Machine')
            [Environment]::SetEnvironmentVariable($ThresholdEnvName, $p, 'Process')
            Restore-PageFileBaseline -Original $Original
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

Write-DexBanner -Title "Invoke-RemediatePageFile_BreakTest" -Detail "Environment: $Environment"

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

        # The two page-file breaks act on the same page file and disagree about the threshold:
        # NearCapacity's zero threshold would turn UnderThreshold's advisory Warning into a
        # repair and fail its "left unmodified" validation. Keep whichever the seeded shuffle
        # drew first so both get coverage across seeds; test them together only by seed.
        $exclusive = @('PageFileManualUnderThreshold', 'PageFileManualNearCapacity')
        if (@($selected | Where-Object { $exclusive -contains $_.Name }).Count -gt 1) {
            $keep     = @($selected | Where-Object { $exclusive -contains $_.Name })[0].Name
            $selected = @($selected | Where-Object { ($exclusive -notcontains $_.Name) -or ($_.Name -eq $keep) })
            Write-DexStep -Status 'Info' -Name 'Selection' -Message "page-file breaks are mutually exclusive; kept '$keep'"
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
