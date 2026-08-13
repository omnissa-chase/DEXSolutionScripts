<#
.SYNOPSIS
    Invoke-AutoRemediateDriverIssues_BreakTest -- deliberately breaks PnP driver state,
    then verifies Invoke-AutoRemediateDriverIssues.ps1 actually fixes it.

.DESCRIPTION
    Break -> verify-the-break -> remediate -> validate -> restore. Writes a uniform
    JSON result to C:\Temp\FixReport\Invoke-AutoRemediateDriverIssues\ for
    Invoke-FixReportAnalysis.ps1 to aggregate.

    THERE IS NO TOOL THAT "INSTALLS A DAMAGED DRIVER", AND NONE IS NEEDED. The script
    under test keys entirely off Win32_PnPEntity.ConfigManagerErrorCode, so any inbox
    mechanism that drives that value non-zero is a faithful break. Two are used here,
    both fully reversible and neither requiring a third-party tool such as DevCon:

      UsbDriverDisabled    -- Disable-PnpDevice yields CM error 22 (device disabled).
                              Same technique as AudioDriverDisabled in
                              Invoke-AutoRemediateAudioBluetooth_BreakTest.ps1.
      DriverPackageDeleted -- pnputil /delete-driver /uninstall /force strips the driver
                              package outright, yielding CM error 28 (drivers not
                              installed) -- the closest safe analogue to a genuinely
                              damaged driver.

    ESCALATION BOUNDARY -- WHY THE DEFAULT ACTIONS ARE NOT THE SCRIPT'S DEFAULT
    A disabled device carries CONFIGFLAG_DISABLED in its Enum key. Neither
    pnputil /scan-devices nor /restart-device nor /rollback-driver clears that flag --
    only removing the device node and re-enumerating does. Both breaks below therefore
    need the Reinstall stage, which is NOT in the target script's own default
    -AllowedActions (Scan, Restart, Rollback). -RemediationAllowedActions consequently
    defaults to Scan, Restart, Rollback, Reinstall so the breaks are fixable at all.
    Re-running with -RemediationAllowedActions Scan,Restart,Rollback is a deliberate
    probe of that boundary and is EXPECTED to report Failed -- that is the harness
    measuring where escalation becomes necessary, not a defect.

    WHY DriverPackageDeleted IS OPT-IN
    pnputil /delete-driver only operates on packages published into the driver store as
    oemN.inf. USB host controllers on most hosts (and on essentially every VM) run the
    inbox usbxhci.inf, which has no oemN.inf entry and cannot be deleted. The break
    therefore hunts for any device backed by a real oemN.inf package and throws a clear
    not-applicable error when none exists -- the same posture AudioDriverDisabled takes
    on a VM with no audio hardware. It is gated behind -IncludeDriverPackageBreak so a
    default run stays portable, mirroring how -IncludeRebootBreaks gates the Printer
    harness's reboot-required break.

    NET AND DISPLAY ARE EXCLUDED from DriverPackageDeleted's device search on purpose:
    deleting a network driver can sever the very session driving this test, and deleting
    a display driver can blank the console. Both are exactly the class of self-inflicted
    lockout the Network Stack harness defers for the same reason.

    VERIFY-THE-BREAK
    Every break is followed by a probe proving the component is genuinely broken.
    A break that silently no-ops would let the remediation "pass" against a healthy
    machine -- a false green.

.PARAMETER RemediationTest
    After breaking, run Invoke-AutoRemediateDriverIssues.ps1 and validate the outcome.
    Without this the script breaks and reports only.

.PARAMETER RemediationAllowedActions
    Passed straight through to the target script's -AllowedActions. Defaults to
    Scan, Restart, Rollback, Reinstall -- see ESCALATION BOUNDARY above.

.PARAMETER IncludeDriverPackageBreak
    Allow the DriverPackageDeleted break. Default off; requires an oemN.inf-backed
    device in a safe class.

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
    catalog today -- neither break requires one -- kept for framework symmetry).

.PARAMETER Force
    Required acknowledgement that this machine will be broken.

.NOTES
    Script Name  : Invoke-AutoRemediateDriverIssues_BreakTest.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : Administrator (elevated)
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-12
    Reporting    : C:\Temp\FixReport\Invoke-AutoRemediateDriverIssues\

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
    [ValidateSet('Scan', 'Restart', 'Rollback', 'Reinstall', 'Uninstall')]
    [string[]]$RemediationAllowedActions = @('Scan', 'Restart', 'Rollback', 'Reinstall'),
    [switch]$IncludeDriverPackageBreak,
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

$ScriptUnderTest   = 'Invoke-AutoRemediateDriverIssues'
$RemediationScript = Join-Path $PSScriptRoot '..\Invoke-AutoRemediateDriverIssues.ps1'
$SelfPath          = $MyInvocation.MyCommand.Path

$modulePath = Join-Path $PSScriptRoot '..\..\AutomatedTesting\DEXTestFramework.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    throw "DEXTestFramework.psm1 not found at $modulePath"
}
Import-Module $modulePath -Force

# Same class regex the target scripts use for USB / Dock devices.
$UsbPattern        = 'usb.*host controller|xhci|thunderbolt|displaylink|usb.*dock|universal serial bus.*host'
$UsbExcludePattern = 'usb.*composite|usb.*hub'

# Classes DriverPackageDeleted may target. Net and Display are absent by design.
$SafeDeletePattern = 'audio|sound|realtek|conexant|IDT|Intel.*Smart Sound|smbus|system management bus|' +
                     'Intel.*Serial IO|chipset|camera|webcam|imaging device|touchpad|synaptics|' +
                     'alps|elan.*pointing|usb.*host controller|xhci'

# -- Helpers -------------------------------------------------------------------

function Get-PnpEntityById {
    param([string]$DeviceId)
    Get-WmiObject -Class Win32_PnPEntity -ErrorAction SilentlyContinue |
        Where-Object { $_.DeviceID -eq $DeviceId } |
        Select-Object -First 1
}

function Get-UsbHostControllerDevice {
    # Deterministic pick so Capture/Apply/Verify/Validate all resolve to the same device.
    $all = @(Get-WmiObject -Class Win32_PnPEntity -ErrorAction SilentlyContinue |
             Where-Object {
                 $_.Name -match $UsbPattern -and
                 $_.Name -notmatch $UsbExcludePattern -and
                 $_.ConfigManagerErrorCode -eq 0
             } |
             Sort-Object -Property DeviceID)

    # Disabling the only USB host controller can strand the keyboard and mouse.
    if ($all.Count -lt 2) { return $null }
    return $all[0]
}

function Get-OemPackagedDevice {
    # Only oemN.inf packages can be deleted from the driver store; inbox INFs cannot.
    $oemDrivers = @(Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
                    Where-Object { $_.InfName -match '^oem\d+\.inf$' -and $_.DeviceID } |
                    Sort-Object -Property DeviceID)
    if ($oemDrivers.Count -eq 0) { return $null }

    $entities = @{}
    foreach ($e in (Get-WmiObject -Class Win32_PnPEntity -ErrorAction SilentlyContinue)) {
        $entities[$e.DeviceID] = $e
    }

    foreach ($drv in $oemDrivers) {
        $dev = $entities[$drv.DeviceID]
        if ($dev -and $dev.ConfigManagerErrorCode -eq 0 -and $dev.Name -match $SafeDeletePattern) {
            return [pscustomobject]@{
                DeviceId   = $dev.DeviceID
                DeviceName = $dev.Name
                InfName    = $drv.InfName
            }
        }
    }
    return $null
}

function Invoke-RemediationUnderTest {
    <#
        -File cannot pass a multi-value ValidateSet parameter: a comma-joined value
        arrives as one literal string and fails validation, and space-separated values
        bind only the first element. -Command re-parses normally, so it is used here.
    #>
    param(
        [Parameter(Mandatory = $true)][hashtable]$State,
        [Parameter(Mandatory = $true)][string[]]$AllowedActions
    )

    # The target script takes a name regex, but delete-driver can rename a device to
    # "Unknown device", so the filter is rebuilt from names read back now, not at capture.
    $names = @()
    foreach ($b in @($State.Breaks)) {
        $id  = $b.OriginalState.DeviceId
        $dev = if ($id) { Get-PnpEntityById -DeviceId $id } else { $null }
        $n   = if ($dev) { $dev.Name } else { $b.OriginalState.DeviceName }
        if ($n) { $names += $n }
    }
    $names = @($names | Select-Object -Unique)
    if ($names.Count -eq 0) { throw 'No target device names resolved; cannot build -DriverFilter.' }

    $filter    = ($names | ForEach-Object { [regex]::Escape($_) }) -join '|'
    $actionArg = ($AllowedActions | ForEach-Object { "'" + $_ + "'" }) -join ','

    $cmd = "& '" + $RemediationScript.Replace("'", "''") + "'" +
           " -DriverFilter '" + $filter.Replace("'", "''") + "'" +
           " -AllowedActions $actionArg; exit `$LASTEXITCODE"

    $sw     = [System.Diagnostics.Stopwatch]::StartNew()
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $cmd 2>&1
    $rc     = $LASTEXITCODE
    $sw.Stop()

    return @{
        ExitCode    = $rc
        DurationSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        Output      = ($output | Out-String).Trim()
    }
}

# -- Break definitions ---------------------------------------------------------
# Capture runs before any mutation; Restore consumes what it returned.
# Verify proves the break landed. Validate decides whether remediation did its job.
$BreakCatalog = @(

    @{
        Name            = 'UsbDriverDisabled'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        OptIn           = $false
        Methods         = @(
            @{
                Name  = 'DisablePnpDevice'
                Apply = {
                    if (-not $script:UsbTargetDeviceId) { throw 'Capture did not resolve a USB host controller.' }
                    Disable-PnpDevice -InstanceId $script:UsbTargetDeviceId -Confirm:$false -ErrorAction Stop
                    Start-Sleep -Seconds 2
                }
            }
        )
        Capture  = {
            $dev = Get-UsbHostControllerDevice
            if (-not $dev) {
                throw 'No healthy USB host controller pair found; cannot test UsbDriverDisabled (needs at least two so the machine keeps a working controller).'
            }
            $script:UsbTargetDeviceId = $dev.DeviceID
            @{ DeviceId = $dev.DeviceID; DeviceName = $dev.Name }
        }
        Verify   = {
            $dev = Get-PnpEntityById -DeviceId $script:UsbTargetDeviceId
            (-not $dev) -or ($dev.ConfigManagerErrorCode -ne 0)
        }
        Validate = {
            $dev  = Get-PnpEntityById -DeviceId $script:UsbTargetDeviceId
            $code = if ($dev) { $dev.ConfigManagerErrorCode } else { -1 }
            @{ Passed = ($code -eq 0); Detail = "ConfigManagerErrorCode=$code" }
        }
        Restore  = {
            param($Original)
            # Safety net regardless of whether the remediation's own escalation worked.
            Enable-PnpDevice -InstanceId $Original.DeviceId -Confirm:$false -ErrorAction SilentlyContinue
        }
    },

    @{
        Name            = 'DriverPackageDeleted'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        OptIn           = $true
        Methods         = @(
            @{
                Name  = 'PnputilDeleteDriver'
                Apply = {
                    if (-not $script:DeepTargetInf) { throw 'Capture did not resolve an OEM driver package.' }
                    pnputil /delete-driver $script:DeepTargetInf /uninstall /force 2>&1 | Out-Null
                    pnputil /scan-devices 2>&1 | Out-Null
                    Start-Sleep -Seconds 5
                }
            }
        )
        Capture  = {
            $target = Get-OemPackagedDevice
            if (-not $target) {
                throw 'No oemN.inf-backed device found in a safe device class; DriverPackageDeleted is not applicable on this host (inbox driver packages cannot be deleted from the driver store).'
            }

            # Exported first so Restore can reinstate the package even if remediation fails.
            $exportDir = Join-Path $env:TEMP "DEXDriverExport_$($target.InfName -replace '\.inf$', '')"
            if (Test-Path -LiteralPath $exportDir) { Remove-Item -LiteralPath $exportDir -Recurse -Force -ErrorAction SilentlyContinue }
            New-Item -ItemType Directory -Path $exportDir -Force -ErrorAction Stop | Out-Null

            pnputil /export-driver $target.InfName $exportDir 2>&1 | Out-Null
            $exported = Get-ChildItem -LiteralPath $exportDir -Recurse -Filter '*.inf' -ErrorAction SilentlyContinue |
                        Select-Object -First 1
            if (-not $exported) {
                throw "pnputil /export-driver produced no INF for $($target.InfName); refusing to delete a package that cannot be restored."
            }

            $script:DeepTargetDeviceId = $target.DeviceId
            $script:DeepTargetInf      = $target.InfName

            @{
                DeviceId    = $target.DeviceId
                DeviceName  = $target.DeviceName
                InfName     = $target.InfName
                ExportedInf = $exported.FullName
                ExportDir   = $exportDir
            }
        }
        Verify   = {
            $dev = Get-PnpEntityById -DeviceId $script:DeepTargetDeviceId
            (-not $dev) -or ($dev.ConfigManagerErrorCode -ne 0)
        }
        Validate = {
            $dev  = Get-PnpEntityById -DeviceId $script:DeepTargetDeviceId
            $code = if ($dev) { $dev.ConfigManagerErrorCode } else { -1 }
            @{ Passed = ($code -eq 0); Detail = "ConfigManagerErrorCode=$code" }
        }
        Restore  = {
            param($Original)
            if ($Original.ExportedInf -and (Test-Path -LiteralPath $Original.ExportedInf)) {
                pnputil /add-driver $Original.ExportedInf /install 2>&1 | Out-Null
                pnputil /scan-devices 2>&1 | Out-Null
                Start-Sleep -Seconds 5
            }
            if ($Original.ExportDir -and (Test-Path -LiteralPath $Original.ExportDir)) {
                Remove-Item -LiteralPath $Original.ExportDir -Recurse -Force -ErrorAction SilentlyContinue
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

Write-DexBanner -Title 'Invoke-AutoRemediateDriverIssues_BreakTest' -Detail "Environment: $Environment"

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
    # Switch parameters cannot survive the reboot, so they come back from persisted state.
    $RemediationTest           = [bool]$state.RemediationTest
    $RemediationAllowedActions = @($state.RemediationAllowedActions)

    # Verify/Validate resolve their target through script-scope ids that a new process lost.
    foreach ($b in @($state.Breaks)) {
        switch ($b.Name) {
            'UsbDriverDisabled'    { $script:UsbTargetDeviceId  = $b.OriginalState.DeviceId }
            'DriverPackageDeleted' {
                $script:DeepTargetDeviceId = $b.OriginalState.DeviceId
                $script:DeepTargetInf      = $b.OriginalState.InfName
            }
        }
    }
} else {
    $state = New-DexTestContext -ScriptUnderTest $ScriptUnderTest -Seed $Seed -Environment $Environment
    $state.RemediationTest           = [bool]$RemediationTest
    $state.RemediationAllowedActions = @($RemediationAllowedActions)
    Write-DexStep -Status 'Info' -Name 'Context' -Message "TestId $($state.TestId)  Seed $($state.Seed)"
    Write-DexStep -Status 'Info' -Name 'Actions' -Message "-AllowedActions $($RemediationAllowedActions -join ', ')"
    if ('Reinstall' -notin $RemediationAllowedActions -and 'Uninstall' -notin $RemediationAllowedActions) {
        Write-DexStep -Status 'Warning' -Name 'Actions' `
                      -Message 'neither Reinstall nor Uninstall permitted; both breaks are expected to remain unfixed.'
    }
}

$exitCode = 0

try {
    # -- Phase: apply breaks ---------------------------------------------------
    if ($state.Phase -eq 'Init') {

        $candidates = if ($BreakName) {
            @($BreakCatalog | Where-Object { $BreakName -contains $_.Name })
        } else {
            @($BreakCatalog | Where-Object { -not $_.OptIn -or $IncludeDriverPackageBreak })
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

            $state.Remediation = Invoke-RemediationUnderTest -State $state -AllowedActions $RemediationAllowedActions
            $state.Phase       = 'Remediated'
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
            # Remediation claimed success while a device is still in error.
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
