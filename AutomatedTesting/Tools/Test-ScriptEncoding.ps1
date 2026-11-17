#Requires -Version 5.1
<#
.SYNOPSIS
    Pre-publish check for deployable scripts and sensors: no UTF-8 byte-order mark, ASCII only,
    and under the pre-2607 UEM size limit.

.DESCRIPTION
    A UTF-8 BOM that reaches Hub's script host as text becomes U+FEFF at the start of the script.
    PowerShell then reads the first token as '﻿<#' or '﻿#Requires' instead of a comment, so
    the comment body is parsed as code and the script fails before its first line runs (5.1 and 7
    alike; ADEX-548). Our UEM connector strips the BOM on upload, so a connector pass does not prove
    a script is safe for a customer who uploads the file in the console.

    Non-ASCII text is flagged because a file without a BOM that contains it is read as ANSI by
    Windows PowerShell 5.1 when run from disk, which garbles strings. ASCII-only files need no BOM.

    Checks every tracked .ps1 outside AutomatedTesting, _AutomatedTesting, Archived and the
    underscore-prefixed scratch files at the repository root, or the
    files passed with -Path. Exit 1 when any file has a BOM or non-ASCII text; size findings are
    reported but do not fail the check, because some on-disk scripts are exempt from the limit
    (GENERAL-SCRIPTS-SENSORS_RUNBOOK.md rule 15).

.PARAMETER Path
    Files to check. Defaults to every tracked deployable .ps1 in the repository.

.PARAMETER Fix
    Strip the BOM from flagged files (writes UTF-8 without BOM). Non-ASCII text is never changed
    automatically: replace it by hand, then rerun.

.EXAMPLE
    .\AutomatedTesting\Tools\Test-ScriptEncoding.ps1

.EXAMPLE
    .\AutomatedTesting\Tools\Test-ScriptEncoding.ps1 -Path .\DiskCleanup\Start-DiskCleanup.ps1 -Fix

.NOTES
    Version      : 1.0.1
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-16 (1.0.1: a comma list passed through -File is split, and a path that does not
                   exist fails the check; 1.0.0 errored on it and still printed OK. 1.0.0: first build after
                   ADEX-548: 28 scripts carried a BOM, 8 had non-ASCII text)
#>
param(
    [string[]]$Path,
    [switch]$Fix
)

$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not $Path) {
    Push-Location $repo
    try {
        # Root-level files starting with '_' are scratch files (e.g. _tmp_sensor_debug.ps1), not deployable.
        $Path = @(git ls-files '*.ps1' | Where-Object { $_ -notmatch '(^|/)(_?AutomatedTesting|Archived)/' -and $_ -notmatch '^_[^/]*$' } | ForEach-Object { Join-Path $repo $_ })
    } finally { Pop-Location }
}

else {
    # Under powershell.exe -File a comma list arrives as one string; split it so every file is checked.
    $Path = @($Path | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

$limit = 32767
$failed = 0
foreach ($p in $Path) {
    # A path that cannot be read is a failure, never a silent pass.
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { '{0,-60} NOT FOUND' -f $p; $failed++; continue }
    $full = (Resolve-Path -LiteralPath $p).Path
    $bytes = [IO.File]::ReadAllBytes($full)
    $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $text = [IO.File]::ReadAllText($full)
    $nonAscii = [regex]::Matches($text, '[^\x00-\x7F]')
    $problems = New-Object System.Collections.Generic.List[string]
    if ($bom) { $problems.Add('BOM') }
    if ($nonAscii.Count -gt 0) {
        $codes = ($nonAscii | ForEach-Object { 'U+{0:X4}' -f [int][char]$_.Value } | Sort-Object -Unique) -join ','
        $problems.Add("non-ASCII x$($nonAscii.Count) ($codes)")
    }
    $size = if ($text.Length -gt $limit) { "  size $($text.Length) > $limit" } else { '' }
    if ($problems.Count -eq 0 -and -not $size) { continue }
    if ($problems.Count -gt 0) { $failed++ }
    if ($Fix -and $bom) {
        [IO.File]::WriteAllText($full, $text, (New-Object System.Text.UTF8Encoding($false)))
        $problems[0] = 'BOM (stripped)'
    }
    $rel = if ($full.StartsWith($repo)) { $full.Substring($repo.Length + 1) } else { $full }
    '{0,-60} {1}{2}' -f $rel, ($problems -join '; '), $size
}
if ($failed -gt 0) { Write-Output "FAILED: $failed file(s) with a BOM or non-ASCII text, or not found"; exit 1 }
Write-Output "OK: $(@($Path).Count) file(s), no BOM, ASCII only"
exit 0
