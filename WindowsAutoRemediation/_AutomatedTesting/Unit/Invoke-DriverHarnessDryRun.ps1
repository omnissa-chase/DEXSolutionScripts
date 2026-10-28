<#
.SYNOPSIS
    Invoke-DriverHarnessDryRun -- runs the two driver break-test HARNESSES end to end with
    stubbed hardware. Non-destructive, no elevation.

.DESCRIPTION
    The *_BreakTest.ps1 harnesses are themselves code that can be wrong, and a harness bug
    costs a whole lab run (the first real run on 2026-10-28 died before applying any break
    because a helper unwrapped a one-element array). This script proves the harness control
    flow -- Capture, Apply, Verify, Remediate, Validate, Restore, result JSON -- without
    touching a real device:

      1. Copies DEXTestFramework.psm1, both driver scripts and both driver harnesses into a
         scratch tree under %TEMP%. The framework copy is patched to skip the elevation check
         and to write its FixReport under the scratch tree (so the real C:\Temp\FixReport is
         never polluted with fake results). The harness copies lose #Requires -RunAsAdministrator.
      2. Runs each harness in a child PowerShell 5.1 with these stubs: Get-WmiObject (fake
         fleet of two USB host controllers plus audio and NIC), Disable-PnpDevice (sets
         CM error 22), Enable-PnpDevice (clears it), pnputil (only /remove-device clears a
         code-22 device, matching real CONFIGFLAG_DISABLED behaviour), Start-Sleep (no-op),
         and powershell.exe itself, so the remediation script the harness launches runs in a
         nested real powershell.exe with the same stubs and shared fleet state.
      3. Compares each run's Overall against the expectation:
            AllDriverIssues  full escalation            -> Passed
            AllDriverIssues  Scan/Restart/Rollback only -> Failed   (boundary probe)
            DriverIssues     full escalation            -> Passed

    Exit code is the number of mismatches. Invoke-DriverDeviceLabRun.ps1 runs this after the
    unit tests and refuses to break the VM if it fails.

.NOTES
    Script Name  : Invoke-DriverHarnessDryRun.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : Any (no elevation required)
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
    [string]$ScratchRoot = (Join-Path $env:TEMP 'DEXHarnessDryRun'),
    [switch]$KeepScratch
)

$ErrorActionPreference = 'Stop'

$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$fix  = Join-Path $ScratchRoot 'FixReport'
if (Test-Path -LiteralPath $ScratchRoot) { Remove-Item -LiteralPath $ScratchRoot -Recurse -Force }
New-Item -ItemType Directory -Path "$ScratchRoot\AutomatedTesting", "$ScratchRoot\WindowsAutoRemediation\_AutomatedTesting", $fix -Force | Out-Null
Set-Content -LiteralPath "$fix\.dex-test-machine" -Value $env:COMPUTERNAME

Write-Output ''
Write-Output '-- Invoke-DriverHarnessDryRun '.PadRight(64, '-')
Write-Output "   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')   scratch: $ScratchRoot"
Write-Output ('-' * 64)

# -- Patched framework copy ----------------------------------------------------
$fw = Get-Content -LiteralPath "$Repo\AutomatedTesting\DEXTestFramework.psm1" -Raw
$fw = $fw.Replace("`$script:FixReportRoot  = 'C:\Temp\FixReport'", "`$script:FixReportRoot  = '$fix'")
$fw = $fw.Replace("throw 'DEX break tests require an elevated session. Re-run PowerShell as Administrator.'", "Write-Output '  (dry-run: elevation check bypassed)'")
if ($fw -notmatch [regex]::Escape($fix))      { throw 'FixReportRoot patch did not apply; framework text changed?' }
if ($fw -match 'require an elevated session') { throw 'elevation patch did not apply; framework text changed?' }
Set-Content -LiteralPath "$ScratchRoot\AutomatedTesting\DEXTestFramework.psm1" -Value $fw -Encoding UTF8

# -- Scripts under test and harnesses (copied so the repo's current code is what runs) --
foreach ($f in 'Invoke-AutoRemediateAllDriverIssues.ps1', 'Invoke-AutoRemediateDriverIssues.ps1') {
    Copy-Item -LiteralPath "$Repo\WindowsAutoRemediation\$f" -Destination "$ScratchRoot\WindowsAutoRemediation\$f"
}
foreach ($f in 'Invoke-AutoRemediateAllDriverIssues_BreakTest.ps1', 'Invoke-AutoRemediateDriverIssues_BreakTest.ps1') {
    $h = Get-Content -LiteralPath "$Repo\WindowsAutoRemediation\_AutomatedTesting\$f" -Raw
    $h = $h -replace '(?m)^#Requires -RunAsAdministrator\s*\r?\n', ''
    Set-Content -LiteralPath "$ScratchRoot\WindowsAutoRemediation\_AutomatedTesting\$f" -Value $h -Encoding UTF8
}

# -- Fake fleet and stubs -----------------------------------------------------------
$stateFile = Join-Path $ScratchRoot 'devices.json'
$callsFile = Join-Path $ScratchRoot 'calls.log'

function Initialize-Fleet {
    $fleet = @(
        [pscustomobject]@{ Name = 'Standard Enhanced PCI to USB Host Controller';                    DeviceID = 'PCI\VEN_15AD&DEV_0770\FAKE1'; ConfigManagerErrorCode = 0 }
        [pscustomobject]@{ Name = 'Standard USB 3.20 eXtensible Host Controller - 1.20 (Microsoft)'; DeviceID = 'PCI\VEN_15AD&DEV_077A\FAKE2'; ConfigManagerErrorCode = 0 }
        [pscustomobject]@{ Name = 'High Definition Audio Device';                                    DeviceID = 'HDAUDIO\FAKE3';                ConfigManagerErrorCode = 0 }
        [pscustomobject]@{ Name = 'vmxnet3 Ethernet Adapter';                                        DeviceID = 'PCI\FAKE4';                    ConfigManagerErrorCode = 0 }
    )
    ConvertTo-Json -InputObject @{ Devices = $fleet } -Depth 4 | Set-Content -LiteralPath $stateFile -Encoding UTF8
    Set-Content -LiteralPath $callsFile -Value '' -Encoding UTF8
}

$stubs = @"
`$global:DexState = '$stateFile'
`$global:DexCalls = '$callsFile'
function global:Get-Fleet { @((ConvertFrom-Json -InputObject (Get-Content -LiteralPath `$global:DexState -Raw)).Devices) }
function global:Save-Fleet(`$f) { ConvertTo-Json -InputObject @{ Devices = @(`$f) } -Depth 4 | Set-Content -LiteralPath `$global:DexState -Encoding UTF8 }
function global:Set-Code(`$id, `$code) { `$f = Get-Fleet; foreach (`$d in `$f) { if (`$d.DeviceID -eq `$id) { `$d.ConfigManagerErrorCode = `$code } }; Save-Fleet `$f }
function global:Log(`$s) { Add-Content -LiteralPath `$global:DexCalls -Value `$s -Encoding UTF8 }
function global:Get-WmiObject { param(`$Class, `$ErrorAction, `$Filter, `$Namespace)
    foreach (`$d in (Get-Fleet)) { [pscustomobject]@{ Name = `$d.Name; DeviceID = `$d.DeviceID; ConfigManagerErrorCode = [int]`$d.ConfigManagerErrorCode } } }
function global:Disable-PnpDevice { param(`$InstanceId, `$Confirm, `$ErrorAction) Log "Disable-PnpDevice `$InstanceId"; Set-Code `$InstanceId 22 }
function global:Enable-PnpDevice  { param(`$InstanceId, `$Confirm, `$ErrorAction) Log "Enable-PnpDevice `$InstanceId";  Set-Code `$InstanceId 0 }
function global:Start-Sleep { param(`$Seconds, `$Milliseconds) }
function global:pnputil {
    `$line = (`$args | ForEach-Object { [string]`$_ }) -join ' '; Log "pnputil `$line"
    `$verb = ([string]`$args[0]).TrimStart('/')
    if (`$verb -eq 'enum-drivers') { 'Published Name:     oem0.inf'; `$global:LASTEXITCODE = 0; return }
    if (`$verb -eq 'remove-device' -and `$args.Count -gt 1) { Set-Code ([string]`$args[1]) 0 }
    `$global:LASTEXITCODE = 0
}
"@
$stubFile = Join-Path $ScratchRoot 'stubs.ps1'
Set-Content -LiteralPath $stubFile -Value $stubs -Encoding UTF8

# The harness launches the remediation through `& powershell.exe ... -Command <cmd>`. This stub
# intercepts that, prepends the stubs, and runs the command in a real nested powershell.exe.
$psStub = @"
function global:powershell.exe {
    `$i = [array]::IndexOf(`$args, '-Command'); `$cmd = [string]`$args[`$i + 1]
    Log "powershell.exe -Command `$cmd"
    `$boot = Join-Path '$ScratchRoot' ('nested_' + [guid]::NewGuid().ToString('N').Substring(0,6) + '.ps1')
    Set-Content -LiteralPath `$boot -Value (". '$stubFile'`r`n" + `$cmd) -Encoding UTF8
    & "`$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File `$boot 2>&1
    `$global:LASTEXITCODE = `$LASTEXITCODE
}
"@

$verdicts = New-Object System.Collections.Generic.List[object]

function Invoke-OneDryRun {
    param([string]$Harness, [string]$Label, [string]$ExtraArgs = '', [string]$Expect)
    Initialize-Fleet
    $boot = Join-Path $ScratchRoot "boot_$Label.ps1"
    $hp = "$ScratchRoot\WindowsAutoRemediation\_AutomatedTesting\$Harness"
    Set-Content -LiteralPath $boot -Value (". '$stubFile'`r`n$psStub`r`n& '$hp' -BreakName UsbDriverDisabled -RemediationTest -Force -Environment Physical $ExtraArgs`r`nexit `$LASTEXITCODE") -Encoding UTF8

    Write-Output ''
    Write-Output "  >> $Label   expects Overall = $Expect"
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $boot 2>&1
    $rc = $LASTEXITCODE
    $out | ForEach-Object { [string]$_ } | Where-Object { $_ -match '^\s*\[' -or $_ -match 'Exception|error' } | ForEach-Object { Write-Output "       $_" }

    $resultDir = Join-Path $fix ($Harness -replace '_BreakTest\.ps1$', '')
    $json = Get-ChildItem -LiteralPath $resultDir -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
    if (-not $json) {
        Write-Output "     [Failed ] ${Label}: harness wrote no result JSON (exit $rc)"
        $verdicts.Add([pscustomobject]@{ Label = $Label; Expected = $Expect; Overall = ''; Ok = $false })
        return
    }
    $r = Get-Content -LiteralPath $json.FullName -Raw | ConvertFrom-Json
    $calls = (Get-Content -LiteralPath $callsFile | Where-Object { $_ } | ForEach-Object { ($_ -split ' ')[0..1] -join ' ' }) -join ' | '
    $ok = ($r.Overall -eq $Expect)
    Write-Output "     [$(if ($ok) { 'Passed ' } else { 'Failed ' })] ${Label}: Overall=$($r.Overall)  breaks=$(($r.Breaks | ForEach-Object Name) -join ',')  remediationExit=$($r.Remediation.ExitCode)"
    Write-Output "               calls: $calls"
    $verdicts.Add([pscustomobject]@{ Label = $Label; Expected = $Expect; Overall = [string]$r.Overall; Ok = $ok })
    Remove-Item -LiteralPath $json.FullName -Force
}

Invoke-OneDryRun -Harness 'Invoke-AutoRemediateAllDriverIssues_BreakTest.ps1' -Label 'AllDriverIssues-FullEscalation' -Expect 'Passed'
Invoke-OneDryRun -Harness 'Invoke-AutoRemediateAllDriverIssues_BreakTest.ps1' -Label 'AllDriverIssues-BoundaryProbe'  -Expect 'Failed' -ExtraArgs '-RemediationAllowedActions Scan,Restart,Rollback'
Invoke-OneDryRun -Harness 'Invoke-AutoRemediateDriverIssues_BreakTest.ps1'    -Label 'DriverIssues-FullEscalation'    -Expect 'Passed'

$bad = @($verdicts | Where-Object { -not $_.Ok }).Count
Write-Output ''
Write-Output ('-' * 64)
Write-Output "  Harness dry run: $($verdicts.Count - $bad) of $($verdicts.Count) scenarios matched expectation"
Write-Output ('-' * 64)
Write-Output ''

if (-not $KeepScratch) { Remove-Item -LiteralPath $ScratchRoot -Recurse -Force -ErrorAction SilentlyContinue }
exit $bad
