<#
.SYNOPSIS
    Invoke-DriverDeviceLabRun -- one-command lab run for the driver and device remediation scripts.

.DESCRIPTION
    Automates LAB-RUN-DriverAndDevice.md end to end on a snapshotted test VM:

        0. Preflight    elevation, Windows PowerShell 5.1, test-host marker, free disk,
                        console session, harness files present
        1. Unit tests   Unit\Invoke-DriverUnitTests.ps1 (non-destructive). Any failure
                        aborts the run: there is no point breaking the VM to find a logic bug.
        2. Break tests  every applicable break in each of the six harnesses, each in its
                        own process, with the result JSON captured per step:
                            AllDriverIssues   UsbDriverDisabled, full escalation (expects Passed)
                            DriverIssues      UsbDriverDisabled, full escalation (expects Passed)
                            AllDriverIssues   UsbDriverDisabled, Scan/Restart/Rollback only
                                              -- the escalation-boundary probe (EXPECTS Failed)
                            AudioBluetooth    all 5 breaks
                            NetworkStack      both breaks (DHCP release/renew: brief net gap)
                            WindowsUpdates    all 4 breaks
                            Printer           the 3 non-reboot breaks
        3. Analysis     AutomatedTesting\Invoke-FixReportAnalysis.ps1, then a per-step
                        verdict table comparing each Overall against what was expected
        4. Optional     -IncludeRebootBreaks launches the Printer PrintFoundationFeature
                        break LAST. It reboots the VM twice and resumes itself. When the VM
                        is back, run this script again with -AnalyzeOnly.
        5. Optional     -UpdateInventory flips SCRIPT-INVENTORY-CSV.csv rows to
                        "4) Complete - Tested" for every script whose runs all passed.

    Each harness restores its own breaks (-Environment Physical, the default) so later
    steps start from a clean machine. The snapshot is the safety net for a Dirty result.
    A Dirty result, or a harness that produced no result file, stops the run immediately.
    Other failures are recorded and the run continues unless -StopOnFailure is given.

    Everything written by this orchestrator goes under C:\Temp\DEXLabRuns\LabRun_<timestamp>\
    (logs, manifest.json, LabRunSummary.csv). The harnesses' own JSON stays under
    C:\Temp\FixReport as usual.

.PARAMETER Force
    Required for a destructive run. Acknowledges that the VM will be broken and that a
    snapshot exists to revert to.

.PARAMETER PlanOnly
    Print the exact commands that would run and exit. Needs no elevation.

.PARAMETER AnalyzeOnly
    Skip breaking anything: re-run the analysis and the verdict table for the most recent
    lab run (used after the reboot-requiring Printer break has finished). Needs no elevation.

.PARAMETER SkipUnitTests
    Do not run the unit tests first. Not recommended.

.PARAMETER IncludeRebootBreaks
    Also run the Printer PrintFoundationFeature break as the final step. Reboots the VM.

.PARAMETER IncludeDriverPackageBreak
    Also run the DriverPackageDeleted break in both driver harnesses. Only applicable on a
    host with an oemN.inf-backed device in a safe class (audio, chipset, camera, touchpad,
    USB host controller). Not applicable on a stock VMware VM.

.PARAMETER UpdateInventory
    After analysis, set the inventory Status to "4) Complete - Tested" for each script
    whose non-probe runs all came back Passed.

.PARAMETER StopOnFailure
    Stop at the first step whose Overall does not match the expectation.

.PARAMETER Include
    Wildcard applied to step ids, e.g. 'AllDriverIssues*' or '*Printer*'.

.PARAMETER Environment
    Passed through to every harness. Physical (default) restores after each run.

.PARAMETER MinFreeGB
    Minimum free space on the system drive before the run is allowed to start.

.EXAMPLE
    .\Invoke-DriverDeviceLabRun.ps1 -PlanOnly
    .\Invoke-DriverDeviceLabRun.ps1 -Force
    .\Invoke-DriverDeviceLabRun.ps1 -Force -IncludeRebootBreaks -UpdateInventory
    .\Invoke-DriverDeviceLabRun.ps1 -AnalyzeOnly -UpdateInventory      # after the reboots

.NOTES
    Script Name  : Invoke-DriverDeviceLabRun.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : Administrator (elevated), Windows PowerShell 5.1, VM console session
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-10-28

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>
#Requires -Version 5.1

param(
    [switch]$Force,
    [switch]$PlanOnly,
    [switch]$AnalyzeOnly,
    [switch]$SkipUnitTests,
    [switch]$IncludeRebootBreaks,
    [switch]$IncludeDriverPackageBreak,
    [switch]$UpdateInventory,
    [switch]$StopOnFailure,
    [string]$Include = '*',
    [ValidateSet('Snapshot', 'Physical')][string]$Environment = 'Physical',
    [string]$FixReportPath = 'C:\Temp\FixReport',
    [string]$LabRunRoot = 'C:\Temp\DEXLabRuns',
    [string[]]$ProductionDomainDenyList = @(),
    [int]$MinFreeGB = 5
)

$ErrorActionPreference = 'Stop'

# -- Paths ---------------------------------------------------------------------
$HarnessDir    = $PSScriptRoot
$RepoRoot      = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$FrameworkPath = Join-Path $RepoRoot 'AutomatedTesting\DEXTestFramework.psm1'
$AnalysisPath  = Join-Path $RepoRoot 'AutomatedTesting\Invoke-FixReportAnalysis.ps1'
$UnitRunner    = Join-Path $PSScriptRoot 'Unit\Invoke-DriverUnitTests.ps1'
$HarnessDryRun = Join-Path $PSScriptRoot 'Unit\Invoke-DriverHarnessDryRun.ps1'
$InventoryCsv  = Join-Path $RepoRoot 'SCRIPT-INVENTORY-CSV.csv'
$LatestPointer = Join-Path $LabRunRoot 'latest.txt'

# -- Output helpers (house style) ----------------------------------------------
function Write-Banner { param([string]$Title, [string]$Detail = '')
    Write-Output ''
    Write-Output "-- $Title ".PadRight(64, '-')
    Write-Output "   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')   $Detail"
    Write-Output ('-' * 64)
}
function Write-Step { param([string]$Status, [string]$Name, [string]$Message = '')
    Write-Output "  [$($Status.PadRight(7))] $Name$(if ($Message) { ": $Message" })"
}
# Tee-Object in PowerShell 5.1 writes UTF-16 with no way to change it; keep logs UTF-8 so
# grep, Select-String and git all read them.
function Write-TeeLog { param([string]$Path)
    process { Add-Content -LiteralPath $Path -Value ([string]$_) -Encoding UTF8; $_ }
}

# -- Plan ----------------------------------------------------------------------
# Args is rendered to PowerShell source and run via -Command, because -File cannot pass a
# multi-value ValidateSet parameter such as -RemediationAllowedActions.
function ConvertTo-PlanStep { param($Id, $Harness, $Script, [hashtable]$Arguments, $Expected, $Note, [bool]$Reboots = $false)
    @{ Id = $Id; Harness = $Harness; Script = $Script; Arguments = $Arguments; Expected = $Expected; Note = $Note; Reboots = $Reboots }
}

$Plan = @(
    ConvertTo-PlanStep -Id 'AllDriverIssues-UsbDisabled' -Harness 'Invoke-AutoRemediateAllDriverIssues_BreakTest.ps1' -Script 'Invoke-AutoRemediateAllDriverIssues' `
        -Arguments @{ BreakName = 'UsbDriverDisabled'; RemediationTest = $true } -Expected 'Passed' `
        -Note 'Full sweep must classify the disabled EHCI controller as USB / Dock and reinstall it (default harness actions include Reinstall).'
    ConvertTo-PlanStep -Id 'DriverIssues-UsbDisabled' -Harness 'Invoke-AutoRemediateDriverIssues_BreakTest.ps1' -Script 'Invoke-AutoRemediateDriverIssues' `
        -Arguments @{ BreakName = 'UsbDriverDisabled'; RemediationTest = $true } -Expected 'Passed' `
        -Note 'Targeted script receives -DriverFilter naming the broken device.'
    ConvertTo-PlanStep -Id 'AllDriverIssues-BoundaryProbe' -Harness 'Invoke-AutoRemediateAllDriverIssues_BreakTest.ps1' -Script 'Invoke-AutoRemediateAllDriverIssues' `
        -Arguments @{ BreakName = 'UsbDriverDisabled'; RemediationTest = $true; RemediationAllowedActions = @('Scan', 'Restart', 'Rollback') } -Expected 'Failed' `
        -Note 'Escalation-boundary probe: the script''s own defaults cannot re-enable a disabled device. Failed here is the correct answer; FalsePass is the defect.'
    ConvertTo-PlanStep -Id 'AudioBluetooth-All' -Harness 'Invoke-AutoRemediateAudioBluetooth_BreakTest.ps1' -Script 'Invoke-AutoRemediateAudioBluetooth' `
        -Arguments @{ BreakCount = 5; RemediationTest = $true } -Expected 'Passed' `
        -Note 'All five catalog breaks in one run.'
    ConvertTo-PlanStep -Id 'NetworkStack-All' -Harness 'Invoke-AutoRemediateNetworkStack_BreakTest.ps1' -Script 'Invoke-AutoRemediateNetworkStack' `
        -Arguments @{ BreakCount = 2; RemediationTest = $true } -Expected 'Passed' `
        -Note 'DhcpLeaseLoss releases and renews the lease: expect a few seconds without network. Run from the VM console.'
    ConvertTo-PlanStep -Id 'WindowsUpdates-All' -Harness 'Invoke-AutoRemediateWindowsUpdates_BreakTest.ps1' -Script 'Invoke-AutoRemediateWindowsUpdates' `
        -Arguments @{ BreakCount = 4; RemediationTest = $true } -Expected 'Passed' `
        -Note 'All four catalog breaks; DataStoreBloated uses a sparse file.'
    ConvertTo-PlanStep -Id 'Printer-NonReboot' -Harness 'Invoke-AutoRemediatePrinter_BreakTest.ps1' -Script 'Invoke-AutoRemediatePrinter' `
        -Arguments @{ BreakCount = 3; RemediationTest = $true } -Expected 'Passed' `
        -Note 'SpoolerService, PrinterOffline, NetworkPrinterUnreachable (the last is report-only).'
)

if ($IncludeDriverPackageBreak) {
    $Plan += ConvertTo-PlanStep -Id 'AllDriverIssues-PackageDeleted' -Harness 'Invoke-AutoRemediateAllDriverIssues_BreakTest.ps1' -Script 'Invoke-AutoRemediateAllDriverIssues' `
        -Arguments @{ BreakName = 'DriverPackageDeleted'; IncludeDriverPackageBreak = $true; RemediationTest = $true } -Expected 'Passed' `
        -Note 'Deletes and reinstalls an oemN.inf package. Not applicable on a stock VMware VM.'
    $Plan += ConvertTo-PlanStep -Id 'DriverIssues-PackageDeleted' -Harness 'Invoke-AutoRemediateDriverIssues_BreakTest.ps1' -Script 'Invoke-AutoRemediateDriverIssues' `
        -Arguments @{ BreakName = 'DriverPackageDeleted'; IncludeDriverPackageBreak = $true; RemediationTest = $true } -Expected 'Passed' `
        -Note 'As above, targeted variant.'
}

if ($IncludeRebootBreaks) {
    $Plan += ConvertTo-PlanStep -Id 'Printer-RebootBreak' -Harness 'Invoke-AutoRemediatePrinter_BreakTest.ps1' -Script 'Invoke-AutoRemediatePrinter' `
        -Arguments @{ BreakName = 'PrintFoundationFeature'; IncludeRebootBreaks = $true; RemediationTest = $true } -Expected 'Passed' -Reboots $true `
        -Note 'REBOOTS THE VM (twice). Runs last; resumes itself via scheduled task. Re-run this script with -AnalyzeOnly afterwards.'
}

$Plan = @($Plan | Where-Object { $_.Id -like $Include })

function ConvertTo-ArgText { param([hashtable]$Arguments)
    $text = ''
    foreach ($k in ($Arguments.Keys | Sort-Object)) {
        $v = $Arguments[$k]
        if ($v -is [bool] -or $v -is [switch]) { if ($v) { $text += " -$k" }; continue }
        $vals = @($v) | ForEach-Object { if ($_ -is [int]) { "$_" } else { "'" + ([string]$_).Replace("'", "''") + "'" } }
        $text += " -$k " + ($vals -join ',')
    }
    $text
}

function Get-StepCommand { param($Step)
    $harnessPath = Join-Path $HarnessDir $Step.Harness
    $argText = ConvertTo-ArgText -Arguments $Step.Arguments
    $argText += " -Environment '$Environment' -Force"
    if ($ProductionDomainDenyList.Count -gt 0) {
        $argText += ' -ProductionDomainDenyList ' + (($ProductionDomainDenyList | ForEach-Object { "'" + $_ + "'" }) -join ',')
    }
    "& '" + $harnessPath.Replace("'", "''") + "'" + $argText + '; exit $LASTEXITCODE'
}

# -- Result helpers ------------------------------------------------------------
function Read-HarnessResult { param([string]$LogPath, [string]$Script, [datetime]$StartedAt)
    # The harnesses pipe Write-DexTestResult to Out-Null, which also swallows its
    # "[Result] <path>" line, so that line is only a bonus. The reliable key is the TestId the
    # harness prints in its Context line: the result file is <FixReport>\<Script>\<TestId>.json.
    # Last resort: the newest JSON for that script written after the step started.
    $jsonPath = $null
    $m = Select-String -LiteralPath $LogPath -Pattern '\[Result\]\s+(.+\.json)\s*$' | Select-Object -Last 1
    if ($m) { $jsonPath = $m.Matches[0].Groups[1].Value.Trim() }

    $scriptDir = Join-Path $FixReportPath $Script
    if (-not ($jsonPath -and (Test-Path -LiteralPath $jsonPath))) {
        $id = Select-String -LiteralPath $LogPath -Pattern 'Context:\s+TestId\s+([0-9a-f]{12})' | Select-Object -Last 1
        if ($id) { $jsonPath = Join-Path $scriptDir ($id.Matches[0].Groups[1].Value + '.json') }
    }
    if (-not ($jsonPath -and (Test-Path -LiteralPath $jsonPath))) {
        $newest = Get-ChildItem -LiteralPath $scriptDir -Filter '*.json' -ErrorAction SilentlyContinue |
                  Where-Object { $StartedAt -and $_.LastWriteTime -ge $StartedAt } |
                  Sort-Object LastWriteTime | Select-Object -Last 1
        if ($newest) { $jsonPath = $newest.FullName }
    }
    if (-not ($jsonPath -and (Test-Path -LiteralPath $jsonPath))) { return $null }

    $r = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json
    @{
        Path    = $jsonPath
        TestId  = $r.TestId
        Overall = [string]$r.Overall
        Breaks  = @($r.Breaks | ForEach-Object { $_.Name }) -join ', '
        Seed    = $r.Seed
    }
}

function Get-Verdict { param([string]$Overall, [string]$Expected)
    if (-not $Overall)               { return 'NO RESULT' }
    if ($Overall -eq $Expected)      { return 'OK' }
    if ($Overall -eq 'Dirty')        { return 'DIRTY - REVERT SNAPSHOT' }
    if ($Expected -eq 'Failed' -and $Overall -eq 'Passed')    { return 'UNEXPECTED PASS (defaults fixed a disabled device?)' }
    if ($Expected -eq 'Failed' -and $Overall -eq 'FalsePass') { return 'FALSE PASS - script claimed success' }
    if ($Overall -eq 'FalsePass')    { return 'FALSE PASS - script claimed success' }
    if ($Overall -eq 'BreakFailed')  { return 'BREAK DID NOT LAND (applicability, not a script bug)' }
    return 'ATTENTION'
}

function Write-SummaryTable { param([object[]]$Rows)
    Write-Output ''
    Write-Output ('  {0,-32} {1,-36} {2,-11} {3,-8} {4}' -f 'Step', 'Breaks', 'Overall', 'Expect', 'Verdict')
    Write-Output ('  ' + ('-' * 110))
    foreach ($r in $Rows) {
        Write-Output ('  {0,-32} {1,-36} {2,-11} {3,-8} {4}' -f $r.Step, ($r.Breaks -replace '^(.{34}).+', '$1..'), $r.Overall, $r.Expected, $r.Verdict)
    }
    Write-Output ''
}

function Write-InventoryStatus { param([object[]]$Rows)
    if (-not (Test-Path -LiteralPath $InventoryCsv)) { Write-Step 'Warning' 'Inventory' "not found: $InventoryCsv"; return }
    $rawCsv = [System.IO.File]::ReadAllText($InventoryCsv)
    $usesCrLf = $rawCsv.Contains("`r`n")
    $csv = Import-Csv -LiteralPath $InventoryCsv
    $changed = 0
    $scripts = $Rows | Where-Object { $_.Expected -eq 'Passed' } | Group-Object Script
    foreach ($g in $scripts) {
        $allPassed = @($g.Group | Where-Object { $_.Overall -ne 'Passed' }).Count -eq 0
        $row = $csv | Where-Object { $_.Name -eq "$($g.Name).ps1" } | Select-Object -First 1
        if (-not $row) { Write-Step 'Warning' 'Inventory' "$($g.Name).ps1 has no inventory row"; continue }
        if ($allPassed) {
            if ($row.Status -ne '4) Complete - Tested') { $row.Status = '4) Complete - Tested'; $changed++ ; Write-Step 'Passed' 'Inventory' "$($g.Name).ps1 -> 4) Complete - Tested" }
            else { Write-Step 'Info' 'Inventory' "$($g.Name).ps1 already Tested" }
        } else {
            Write-Step 'Warning' 'Inventory' "$($g.Name).ps1 left as '$($row.Status)' (not every run passed)"
        }
    }
    if ($changed -gt 0) {
        # Export-Csv always writes CRLF; put the file back to whatever line ending it had so
        # the git diff shows only the changed Status cells.
        $csv | Export-Csv -LiteralPath $InventoryCsv -NoTypeInformation -Encoding UTF8
        if (-not $usesCrLf) {
            $text = [System.IO.File]::ReadAllText($InventoryCsv).Replace("`r`n", "`n")
            [System.IO.File]::WriteAllText($InventoryCsv, $text, (New-Object System.Text.UTF8Encoding($true)))
        }
        Write-Step 'Passed' 'Inventory' "$changed row(s) updated in SCRIPT-INVENTORY-CSV.csv (uncommitted)"
    }
}

function Invoke-Analysis { param([string]$RunDir)
    Write-Banner -Title 'Phase 3: Analysis' -Detail $FixReportPath
    $log = Join-Path $RunDir 'analysis.log'
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $AnalysisPath -Path $FixReportPath 2>&1 | Write-TeeLog -Path $log
    Write-Step 'Info' 'Analysis' "exit $LASTEXITCODE (1 = at least one run needs attention)"
}

# ==============================================================================
# Plan only
# ==============================================================================
Write-Banner -Title 'Invoke-DriverDeviceLabRun' -Detail "Environment: $Environment   Steps: $($Plan.Count)$(if ($PlanOnly) { '   (PLAN ONLY)' } elseif ($AnalyzeOnly) { '   (ANALYZE ONLY)' })"

if ($PlanOnly) {
    Write-Output ''
    Write-Output "  0. Preflight (elevation, PS 5.1, marker at $FixReportPath\.dex-test-machine, >= $MinFreeGB GB free, console session)"
    Write-Output "  1. Unit tests:  powershell.exe -File `"$UnitRunner`"   (abort on any failure)"
    Write-Output "     Dry run:     powershell.exe -File `"$HarnessDryRun`"   (harnesses vs stubs; abort on mismatch)"
    $n = 2
    foreach ($s in $Plan) {
        Write-Output ''
        Write-Output "  $n. $($s.Id)   expects Overall = $($s.Expected)$(if ($s.Reboots) { '   ** REBOOTS THE VM **' })"
        Write-Output "     $($s.Note)"
        Write-Output "     powershell.exe -NoProfile -ExecutionPolicy Bypass -Command `"$(Get-StepCommand $s)`""
        $n++
    }
    Write-Output ''
    Write-Output "  $n. Analysis:   powershell.exe -File `"$AnalysisPath`" -Path $FixReportPath"
    if ($UpdateInventory) { Write-Output "  $($n + 1). Update SCRIPT-INVENTORY-CSV.csv Status for scripts whose runs all passed" }
    Write-Output ''
    exit 0
}

# ==============================================================================
# Analyze only (post-reboot follow-up)
# ==============================================================================
if ($AnalyzeOnly) {
    if (-not (Test-Path -LiteralPath $LatestPointer)) { Write-Step 'Failed' 'AnalyzeOnly' "no previous lab run recorded at $LatestPointer"; exit 1 }
    $runDir = (Get-Content -LiteralPath $LatestPointer -Raw).Trim()
    $manifestPath = Join-Path $runDir 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) { Write-Step 'Failed' 'AnalyzeOnly' "manifest missing: $manifestPath"; exit 1 }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $rows = @($manifest.Results | ForEach-Object { [pscustomobject]@{
        Step = $_.Step; Script = $_.Script; Breaks = $_.Breaks; Overall = $_.Overall; Expected = $_.Expected; Verdict = $_.Verdict; ResultPath = $_.ResultPath } })

    # Pick up the reboot step's result, written after this orchestrator exited.
    $rebootStep = $rows | Where-Object { $_.Step -eq 'Printer-RebootBreak' -and -not $_.Overall }
    if ($rebootStep) {
        $started = [datetime]::Parse($manifest.StartedAt)
        $latest  = Get-ChildItem -LiteralPath (Join-Path $FixReportPath 'Invoke-AutoRemediatePrinter') -Filter '*.json' -ErrorAction SilentlyContinue |
                   Where-Object { $_.LastWriteTime -gt $started } | Sort-Object LastWriteTime | Select-Object -Last 1
        if ($latest) {
            $r = Get-Content -LiteralPath $latest.FullName -Raw | ConvertFrom-Json
            if (@($r.Breaks | ForEach-Object { $_.Name }) -contains 'PrintFoundationFeature') {
                $rebootStep.Overall = [string]$r.Overall; $rebootStep.Breaks = 'PrintFoundationFeature'
                $rebootStep.Verdict = Get-Verdict -Overall $rebootStep.Overall -Expected $rebootStep.Expected
                $rebootStep.ResultPath = $latest.FullName
            }
        }
        if (-not $rebootStep.Overall) { $rebootStep.Verdict = 'STILL RUNNING or no result yet' }
    }

    Invoke-Analysis -RunDir $runDir
    Write-Banner -Title 'Lab run verdicts' -Detail $runDir
    Write-SummaryTable -Rows $rows
    $rows | Export-Csv -LiteralPath (Join-Path $runDir 'LabRunSummary.csv') -NoTypeInformation -Encoding UTF8
    if ($UpdateInventory) { Write-InventoryStatus -Rows $rows }
    $bad = @($rows | Where-Object { $_.Verdict -ne 'OK' }).Count
    exit $(if ($bad -gt 0) { 1 } else { 0 })
}

# ==============================================================================
# Phase 0: preflight
# ==============================================================================
Write-Banner -Title 'Phase 0: Preflight'

if ($PSVersionTable.PSEdition -ne 'Desktop') {
    Write-Step 'Failed' 'PowerShell' "this must run under Windows PowerShell 5.1 (powershell.exe), not $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)"; exit 1
}
Write-Step 'Passed' 'PowerShell' "$($PSVersionTable.PSVersion) Desktop"

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Step 'Failed' 'Elevation' 'open Windows PowerShell as Administrator and re-run'; exit 1
}
Write-Step 'Passed' 'Elevation' 'running as Administrator'

if (-not $Force) {
    Write-Output ''
    Write-Output '  REFUSING TO RUN. This will deliberately break drivers, services, network and printing on this'
    Write-Output '  machine. Take a VM snapshot, then re-run with -Force to acknowledge. Use -PlanOnly to preview.'
    Write-Output ''
    exit 1
}

foreach ($p in @($FrameworkPath, $AnalysisPath, $UnitRunner, $HarnessDryRun)) {
    if (-not (Test-Path -LiteralPath $p)) { Write-Step 'Failed' 'Files' "missing: $p"; exit 1 }
}
foreach ($s in $Plan) {
    $hp = Join-Path $HarnessDir $s.Harness
    if (-not (Test-Path -LiteralPath $hp)) { Write-Step 'Failed' 'Files' "missing harness: $hp"; exit 1 }
}
Write-Step 'Passed' 'Files' "framework, analysis, unit runner and $($Plan.Count) harness step(s) present"

Import-Module $FrameworkPath -Force
Assert-DexTestHost -Force:$Force -ProductionDomainDenyList $ProductionDomainDenyList   # marker, elevation, deny list; prints the banner
Write-Step 'Passed' 'Interlock' "test-host marker present on $env:COMPUTERNAME"

$sys = Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':'))
$freeGB = [math]::Round($sys.Free / 1GB, 1)
if ($freeGB -lt $MinFreeGB) { Write-Step 'Failed' 'Disk' "$freeGB GB free on $env:SystemDrive, need at least $MinFreeGB GB (-MinFreeGB to override)"; exit 1 }
Write-Step 'Passed' 'Disk' "$freeGB GB free on $env:SystemDrive"

if ($env:SESSIONNAME -and $env:SESSIONNAME -notlike 'Console*') {
    Write-Step 'Warning' 'Session' "this is a '$env:SESSIONNAME' session. NetworkStack's DhcpLeaseLoss will drop an RDP session; use the VM console or -Include to skip it."
} else {
    Write-Step 'Passed' 'Session' 'console session'
}

$cbs  = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
$pfro = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
if ($cbs -or $pfro) { Write-Step 'Warning' 'Reboot' 'a reboot is already pending; driver and Windows Update results may be noisier than on a clean boot' }
else { Write-Step 'Passed' 'Reboot' 'no pending reboot' }

if ($Plan.Count -eq 0) { Write-Step 'Failed' 'Plan' "no steps match -Include '$Include'"; exit 1 }

# -- Run directory --------------------------------------------------------------
$runDir = Join-Path $LabRunRoot ("LabRun_" + (Get-Date -Format 'yyyyMMdd_HHmmss'))
New-Item -ItemType Directory -Path $runDir -Force | Out-Null
Set-Content -LiteralPath $LatestPointer -Value $runDir -Encoding UTF8
$manifest = [ordered]@{
    StartedAt   = (Get-Date).ToString('o')
    CompletedAt = $null
    Machine     = $env:COMPUTERNAME
    Environment = $Environment
    Include     = $Include
    Results     = @()
}
function Save-Manifest { $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $runDir 'manifest.json') -Encoding UTF8 }
Save-Manifest
Write-Step 'Info' 'RunDir' $runDir

# ==============================================================================
# Phase 1: unit tests
# ==============================================================================
Write-Banner -Title 'Phase 1: Unit tests (non-destructive)'
if ($SkipUnitTests) {
    Write-Step 'Warning' 'UnitTests' 'skipped by -SkipUnitTests'
} else {
    $unitLog = Join-Path $runDir 'unit-tests.log'
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $UnitRunner 2>&1 |
        Write-TeeLog -Path $unitLog | Where-Object { $_ -match '^\s*\[-\]|Passed:|ASSERT|Exception' }
    $unitRc = $LASTEXITCODE
    if ($unitRc -ne 0) {
        Write-Step 'Failed' 'UnitTests' "$unitRc test(s) failed (see $unitLog). Fix the logic before breaking the VM."
        $manifest.CompletedAt = (Get-Date).ToString('o'); Save-Manifest
        exit 1
    }
    Write-Step 'Passed' 'UnitTests' "all green ($unitLog)"

    # Harness dry run: the break-test harnesses themselves, end to end, against stubbed
    # hardware. Catches harness bugs before they cost a destructive run.
    $dryLog = Join-Path $runDir 'harness-dryrun.log'
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $HarnessDryRun 2>&1 |
        Write-TeeLog -Path $dryLog | Where-Object { $_ -match '^\s*\[(Passed|Failed)|scenarios matched|Exception' }
    $dryRc = $LASTEXITCODE
    if ($dryRc -ne 0) {
        Write-Step 'Failed' 'HarnessDryRun' "$dryRc scenario(s) mismatched (see $dryLog). Fix the harness before breaking the VM."
        $manifest.CompletedAt = (Get-Date).ToString('o'); Save-Manifest
        exit 1
    }
    Write-Step 'Passed' 'HarnessDryRun' "both driver harnesses run clean against stubs ($dryLog)"
}

# ==============================================================================
# Phase 2: break tests
# ==============================================================================
Write-Banner -Title 'Phase 2: Break tests' -Detail "$($Plan.Count) step(s), Environment=$Environment"

$rows = New-Object System.Collections.Generic.List[object]
$stopped = $false
$rebootLaunched = $false

foreach ($step in $Plan) {

    # The reboot step goes last and is handled after analysis so the user gets a summary first.
    if ($step.Reboots) { continue }

    Write-Output ''
    Write-Output "  >> $($step.Id)    expects: $($step.Expected)"
    Write-Output "     $($step.Note)"
    $cmd = Get-StepCommand $step
    $log = Join-Path $runDir "$($step.Id).log"
    $stepStart = (Get-Date).AddSeconds(-2)   # small skew allowance for file timestamps
    $sw  = [System.Diagnostics.Stopwatch]::StartNew()

    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $cmd 2>&1 |
        Write-TeeLog -Path $log | ForEach-Object { "       $_" }
    $rc = $LASTEXITCODE
    $sw.Stop()

    $res = Read-HarnessResult -LogPath $log -Script $step.Script -StartedAt $stepStart
    $overall = if ($res) { $res.Overall } else { '' }
    $verdict = Get-Verdict -Overall $overall -Expected $step.Expected
    if ($res -and -not $res.Breaks -and $overall -ne 'Passed') {
        # The harness wrote a result but never applied a break: it threw before Apply.
        $verdict = 'HARNESS ERROR before any break (see log)'
    }

    $row = [pscustomobject]@{
        Step        = $step.Id
        Script      = $step.Script
        Harness     = $step.Harness
        Breaks      = $(if ($res) { $res.Breaks } else { '' })
        Overall     = $overall
        Expected    = $step.Expected
        Verdict     = $verdict
        HarnessExit = $rc
        DurationSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        ResultPath  = $(if ($res) { $res.Path } else { '' })
        Log         = $log
    }
    $rows.Add($row)
    $manifest.Results = $rows.ToArray()
    Save-Manifest

    Write-Step $(if ($verdict -eq 'OK') { 'Passed' } else { 'Failed' }) $step.Id "Overall=$(if ($overall) { $overall } else { 'none' })  expected=$($step.Expected)  -> $verdict  ($($row.DurationSec)s)"

    if ($overall -eq 'Dirty') {
        Write-Step 'Failed' 'STOP' 'restore failed and the machine is modified. Revert the snapshot before doing anything else.'
        $stopped = $true; break
    }
    if (-not $res) {
        Write-Step 'Failed' 'STOP' "harness produced no result file (exit $rc); machine state unknown. Check $log and consider reverting the snapshot."
        $stopped = $true; break
    }
    if ($verdict -ne 'OK' -and $StopOnFailure) {
        Write-Step 'Failed' 'STOP' '-StopOnFailure set'
        $stopped = $true; break
    }
}

# ==============================================================================
# Phase 3: analysis and verdicts
# ==============================================================================
Invoke-Analysis -RunDir $runDir

Write-Banner -Title 'Lab run verdicts' -Detail $runDir
Write-SummaryTable -Rows $rows.ToArray()
$rows | Export-Csv -LiteralPath (Join-Path $runDir 'LabRunSummary.csv') -NoTypeInformation -Encoding UTF8
$bad = @($rows | Where-Object { $_.Verdict -ne 'OK' }).Count
Write-Step $(if ($bad -eq 0) { 'Passed' } else { 'Failed' }) 'Verdicts' "$($rows.Count - $bad) OK, $bad need attention. Evidence: $FixReportPath\Summary.csv and $runDir"

if ($UpdateInventory -and -not $stopped) { Write-InventoryStatus -Rows $rows.ToArray() }

# ==============================================================================
# Phase 4: reboot-requiring break (last, optional)
# ==============================================================================
$rebootStep = $Plan | Where-Object { $_.Reboots } | Select-Object -First 1
if ($rebootStep -and -not $stopped) {
    Write-Banner -Title 'Phase 4: Reboot-requiring break' -Detail $rebootStep.Id
    Write-Output "     $($rebootStep.Note)"
    $rows.Add([pscustomobject]@{
        Step = $rebootStep.Id; Script = $rebootStep.Script; Harness = $rebootStep.Harness; Breaks = ''
        Overall = ''; Expected = $rebootStep.Expected; Verdict = 'PENDING (reboot)'; HarnessExit = $null
        DurationSec = $null; ResultPath = ''; Log = (Join-Path $runDir "$($rebootStep.Id).log")
    })
    $manifest.Results = $rows.ToArray(); $manifest.CompletedAt = (Get-Date).ToString('o'); Save-Manifest
    Write-Step 'Warning' 'Reboot' 'the VM will restart in about 15 seconds once the break is applied. When it is back, run:'
    Write-Output "           & '$PSCommandPath' -AnalyzeOnly$(if ($UpdateInventory) { ' -UpdateInventory' })"
    Write-Output ''
    $cmd = Get-StepCommand $rebootStep
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $cmd 2>&1 |
        Write-TeeLog -Path (Join-Path $runDir "$($rebootStep.Id).log") | ForEach-Object { "       $_" }
    $rebootLaunched = $true
} elseif ($rebootStep -and $stopped) {
    Write-Step 'Warning' 'Reboot' 'reboot-requiring break skipped because the run stopped early'
}

$manifest.CompletedAt = (Get-Date).ToString('o'); Save-Manifest

Write-Output ''
Write-Output ('-' * 64)
if ($rebootLaunched) {
    Write-Output '  Reboot break launched. Results so far are in the table above; finish with -AnalyzeOnly.'
} elseif ($stopped) {
    Write-Output '  Run stopped early. See the STOP line above.'
} else {
    Write-Output '  Run complete. Revert the snapshot before the next lab run so every run starts from the same baseline.'
}
Write-Output ('-' * 64)
Write-Output ''

exit $(if ($bad -gt 0 -or $stopped) { 1 } else { 0 })
