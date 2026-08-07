<#
.SYNOPSIS
    Invoke-FixReportAnalysis -- aggregates break-test results into a console table and CSV.

.DESCRIPTION
    Reads every *.json result under the FixReport root, summarises each run, and
    highlights the two outcomes that matter most:

      FalsePass -- the remediation script exited 0 and claimed success while the
                   component was still broken. The single highest-value signal this
                   harness produces, and invisible to the remediation script itself.
      Dirty     -- restore failed, so the machine is still modified and needs
                   manual cleanup before it is trusted again.

    Exits 1 when any run ended Failed, FalsePass, BreakFailed, or Dirty, so this can
    gate a pipeline directly.

.PARAMETER Path
    FixReport root. Default C:\Temp\FixReport.

.PARAMETER CsvPath
    Where to write the summary CSV. Defaults to Summary.csv under -Path.

.PARAMETER ScriptUnderTest
    Limit the report to one remediation script.

.NOTES
    Script Name  : Invoke-FixReportAnalysis.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : Any
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-07

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

#Requires -Version 5.1

param(
    [string]$Path = 'C:\Temp\FixReport',
    [string]$CsvPath,
    [string]$ScriptUnderTest
)

if (-not $CsvPath) { $CsvPath = Join-Path $Path 'Summary.csv' }

if (-not (Test-Path -LiteralPath $Path)) {
    Write-Host "No FixReport directory at $Path -- nothing to analyse." -ForegroundColor Yellow
    exit 0
}

# state.json is in-flight run state, not a result.
$files = Get-ChildItem -LiteralPath $Path -Filter '*.json' -Recurse -ErrorAction SilentlyContinue |
         Where-Object { $_.Name -ne 'state.json' }

if ($ScriptUnderTest) {
    $files = $files | Where-Object { $_.Directory.Name -eq $ScriptUnderTest }
}

if (-not $files -or @($files).Count -eq 0) {
    Write-Host "No result files found under $Path." -ForegroundColor Yellow
    exit 0
}

$rows = foreach ($f in $files) {
    try {
        $r = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json
    } catch {
        Write-Host "  [Skip] Unreadable result: $($f.FullName)" -ForegroundColor Yellow
        continue
    }

    $breaks     = @($r.Breaks)
    $validation = @($r.Validation)

    $duration = ''
    if ($r.StartedAt -and $r.CompletedAt) {
        try {
            $duration = '{0:N0}s' -f ([datetime]$r.CompletedAt - [datetime]$r.StartedAt).TotalSeconds
        } catch { $duration = '' }
    }

    [PSCustomObject]@{
        TestId         = $r.TestId
        Script         = $r.ScriptUnderTest
        Seed           = $r.Seed
        Machine        = $r.Machine
        Environment    = $r.Environment
        Overall        = $r.Overall
        BreaksApplied  = @($breaks | Where-Object { $_.Applied }).Count
        BreaksVerified = @($breaks | Where-Object { $_.BreakVerified }).Count
        Validated      = @($validation | Where-Object { $_.Result -eq 'Pass' }).Count
        ValidationFail = @($validation | Where-Object { $_.Result -eq 'Fail' }).Count
        RebootCount    = $r.RebootCount
        Duration       = $duration
        CompletedAt    = $r.CompletedAt
    }
}

$rows = @($rows | Sort-Object Script, CompletedAt)

Write-Host ''
Write-Host '-- Fix Report Analysis '.PadRight(64, '-') -ForegroundColor Cyan
Write-Host "   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')   Runs: $($rows.Count)   Source: $Path"
Write-Host ('-' * 64) -ForegroundColor Cyan

foreach ($group in ($rows | Group-Object Script)) {

    Write-Host ''
    Write-Host "  $($group.Name)" -ForegroundColor White

    foreach ($row in $group.Group) {
        $color = switch ($row.Overall) {
            'Passed'      { 'Green'  }
            'BreakOnly'   { 'Gray'   }
            'Restored'    { 'Gray'   }
            'FalsePass'   { 'Red'    }
            'Dirty'       { 'Red'    }
            'BreakFailed' { 'Yellow' }
            'Abandoned'   { 'Yellow' }
            default       { 'Red'    }
        }

        $line = '    {0}  {1}  seed {2,-11}  breaks {3}/{4}  valid {5}/{6}  {7}' -f `
            $row.TestId.PadRight(12),
            $row.Overall.PadRight(11),
            $row.Seed,
            $row.BreaksVerified, $row.BreaksApplied,
            $row.Validated, ($row.Validated + $row.ValidationFail),
            $row.Duration

        Write-Host $line -ForegroundColor $color
    }
}

# -- Callouts ------------------------------------------------------------------
$falsePass = @($rows | Where-Object { $_.Overall -eq 'FalsePass' })
$dirty     = @($rows | Where-Object { $_.Overall -eq 'Dirty' })
$broken    = @($rows | Where-Object { $_.Overall -eq 'BreakFailed' })

if ($falsePass.Count -gt 0) {
    Write-Host ''
    Write-Host '  FALSE PASS -- remediation reported success but the component was still broken:' -ForegroundColor Red
    foreach ($r in $falsePass) { Write-Host "    $($r.Script)  $($r.TestId)  seed $($r.Seed)  on $($r.Machine)" -ForegroundColor Red }
}

if ($broken.Count -gt 0) {
    Write-Host ''
    Write-Host '  BREAK FAILED -- the break did not land, so the run proves nothing:' -ForegroundColor Yellow
    foreach ($r in $broken) { Write-Host "    $($r.Script)  $($r.TestId)  seed $($r.Seed)" -ForegroundColor Yellow }
}

if ($dirty.Count -gt 0) {
    Write-Host ''
    Write-Host '  DIRTY -- restore failed; these machines need manual cleanup:' -ForegroundColor Red
    foreach ($r in $dirty) { Write-Host "    $($r.Machine)  ($($r.Script), $($r.TestId))" -ForegroundColor Red }
}

# -- Summary -------------------------------------------------------------------
$passed = @($rows | Where-Object { $_.Overall -eq 'Passed' }).Count
$failed = @($rows | Where-Object { $_.Overall -in @('Failed', 'FalsePass', 'BreakFailed', 'Dirty', 'Abandoned') }).Count

Write-Host ''
Write-Host ('-' * 64) -ForegroundColor Cyan
Write-Host "  Passed: $passed  |  Failed: $failed  |  FalsePass: $($falsePass.Count)  |  Dirty: $($dirty.Count)"
Write-Host ('-' * 64) -ForegroundColor Cyan

try {
    $rows | Export-Csv -LiteralPath $CsvPath -NoTypeInformation -Encoding UTF8 -Force -ErrorAction Stop
    Write-Host "  [CSV] $CsvPath" -ForegroundColor DarkCyan
} catch {
    Write-Host "  [CSV] Write failed: $($_.Exception.Message)" -ForegroundColor Yellow
}
Write-Host ''

if ($failed -gt 0) { exit 1 }
exit 0
