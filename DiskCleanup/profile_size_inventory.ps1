#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : profile_size_inventory.ps1
    Data Type    : String (JSON)
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-14
    Timeout      : < 25 seconds (one-time/run-once sensor; MUST NOT be scheduled as a recurring sensor)

    One-time/run-once sensor that reports every non-special local user profile --
    size on disk and days since last login -- as a single JSON payload. Sizes are
    walked with native .NET DirectoryInfo enumeration (see Get-DirectorySizeInfo
    below), the same approach Start-UserProfileCleanup.ps1 uses instead of
    Get-ChildItem, to avoid PowerShell pipeline overhead on large profile trees.

    Unlike Start-UserProfileCleanup.ps1 (which only considers domain-joined,
    non-enrollment-user profiles it might delete), this sensor is read-only and
    reports on every non-special profile regardless of domain -- it is a full
    inventory, not a deletion candidate list.

    Directory walking is wall-clock bounded, not row/byte bounded: a shared
    Stopwatch is checked before descending into each subdirectory, across ALL
    profiles combined, so one huge profile can't starve the others out of the
    budget. Any profile whose size couldn't be fully walked before the deadline
    reports SizeMB -4 (TimedOut) rather than a partial/misleading number, and the
    top-level Truncated flag is set true so downstream knows the sweep didn't
    finish.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

# -- Tunables --
$script:TimeoutSeconds = 25   # Self-enforced deadline; 30s is the UEM one-time-sensor hard ceiling.

function Get-DirectorySizeInfo {
    param(
        [string]$Path,
        [System.Diagnostics.Stopwatch]$Stopwatch,
        [int]$BudgetMs
    )

    [Int64]$totalBytes = 0
    $timedOut = $false

    if (-not (Test-Path -LiteralPath $Path)) {
        return [PSCustomObject]@{ Bytes = 0; TimedOut = $false }
    }

    $stack = [System.Collections.Generic.Stack[string]]::new()
    $stack.Push($Path)

    while ($stack.Count -gt 0) {
        if ($Stopwatch.ElapsedMilliseconds -ge $BudgetMs) { $timedOut = $true; break }
        $current = $stack.Pop()
        try {
            $dirInfo = [System.IO.DirectoryInfo]::new($current)
            foreach ($file in $dirInfo.EnumerateFiles()) {
                try { $totalBytes += $file.Length } catch { }
            }
            foreach ($subDir in $dirInfo.EnumerateDirectories()) {
                # Skip reparse points (legacy profile junctions) to avoid double-counting/loops
                if (($subDir.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
                    $stack.Push($subDir.FullName)
                }
            }
        } catch {
            # Access denied or IO error on this directory -- skip it, keep walking siblings
            continue
        }
    }

    return [PSCustomObject]@{ Bytes = $totalBytes; TimedOut = $timedOut }
}

try {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $budgetMs = $script:TimeoutSeconds * 1000

    $profiles = @(Get-CimInstance -ClassName Win32_UserProfile -ErrorAction Stop | Where-Object { -not $_.Special })

    $results = @(
        foreach ($p in $profiles) {
            $daysSinceLogin = if ($p.LastUseTime) { [math]::Round(((Get-Date) - $p.LastUseTime).TotalDays, 2) } else { -1 }

            if ($sw.ElapsedMilliseconds -ge $budgetMs) {
                # Budget already exhausted by earlier profiles -- report without touching disk
                [PSCustomObject][ordered]@{
                    Username           = Split-Path $p.LocalPath -Leaf
                    LocalPath          = $p.LocalPath
                    SizeMB             = -4
                    DaysSinceLastLogin = $daysSinceLogin
                    Loaded             = [bool]$p.Loaded
                }
                continue
            }

            $sizeInfo = Get-DirectorySizeInfo -Path $p.LocalPath -Stopwatch $sw -BudgetMs $budgetMs

            [PSCustomObject][ordered]@{
                Username           = Split-Path $p.LocalPath -Leaf
                LocalPath          = $p.LocalPath
                SizeMB             = if ($sizeInfo.TimedOut) { -4 } else { [math]::Round($sizeInfo.Bytes / 1MB, 2) }
                DaysSinceLastLogin = $daysSinceLogin
                Loaded             = [bool]$p.Loaded
            }
        }
    )

    $totalSizeMB = ($results | Where-Object { $_.SizeMB -ge 0 } | Measure-Object -Property SizeMB -Sum).Sum
    if (-not $totalSizeMB) { $totalSizeMB = 0 }

    $payload = [ordered]@{
        Status          = 'OK'
        DataCollectedAt = (Get-Date).ToString('s')
        ProfileCount    = $results.Count
        TotalSizeMB     = [math]::Round($totalSizeMB, 2)
        Truncated       = ($sw.ElapsedMilliseconds -ge $budgetMs)
        Profiles        = $results
    }

    Write-Output ($payload | ConvertTo-Json -Compress -Depth 5)
    return
}
catch {
    Write-Output ([PSCustomObject]@{ Status = 'Failed'; Error = $_.Exception.Message } | ConvertTo-Json -Compress)
    return
}
