<#
.SYNOPSIS
    Empties the Recycle Bin for every user on the device, from SYSTEM context.

.DESCRIPTION
    Deletes recycled items directly from the per-user Recycle Bin folders on disk
    rather than going through the shell.

    Why not cleanmgr or Clear-RecycleBin: both resolve the Recycle Bin for the
    account that calls them. UEM runs scripts as SYSTEM, whose bin (S-1-5-18) is
    always empty, because deletions performed by SYSTEM bypass the Recycle Bin
    entirely. A cleanmgr run with the Recycle Bin category therefore reclaims
    nothing on a managed device, no matter how long it is given to finish.

    Recycled items actually live in <drive>:\$Recycle.Bin\<user SID>\ as pairs:
    a $R entry holding the content, which may be a file or a whole folder, and a
    $I sidecar holding the original path and the deletion timestamp. This script
    walks those folders itself, so it is not bound to any one user's context.

    Reports the space reclaimed per user and in total.

.PARAMETER OlderThanDays
    Only remove items deleted more than this many days ago. 0, the default,
    removes everything. Use a value such as 7 to leave recent deletions
    recoverable while still reclaiming the bulk of the space.

.PARAMETER AllFixedDrives
    Process every fixed drive. Default is the system drive only.

.PARAMETER ResetShellIcon
    After emptying a user's bin, delete the now-empty per-user folder so the
    desktop Recycle Bin icon stops showing as full. Off by default. A folder that
    still holds entries, because an age filter retained them, is left alone.

.NOTES
    Script Name  : Start-ClearRecycleBin.ps1
    Data Type    : String
    Version      : 2.2.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-09-04
    Timeout      : 300 seconds. Emptying a very large bin is bounded by disk, not CPU.

    Inputs (UEM script-object variables):
      OlderThanDays    Optional. Whole number of days. Default 0, meaning everything.
      AllFixedDrives   Optional. "true" to include every fixed drive.
      ResetShellIcon   Optional. "true" to clear the stale desktop icon. See below.
      WhatIf           Optional. Only an explicit, parseable "true" enables a dry run.

    Deleting on the filesystem does not notify the shell, so a logged-on user will
    keep seeing a full Recycle Bin icon even though the contents are gone. Explorer
    caches the count per user and only corrects it when something else changes the
    bin. Set ResetShellIcon to "true" to delete the emptied per-user folder, which
    clears that cache; Windows recreates the folder on the user's next delete.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>
function Start-ClearRecycleBin {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
        [int]$OlderThanDays = 0,
        [switch]$AllFixedDrives,
        [switch]$ResetShellIcon
    )

    # Reads the deletion timestamp out of a $I sidecar. Layout on Vista and later:
    # 0-7 version, 8-15 original size, 16-23 deletion time as FILETIME, then the
    # original path. Falls back to the file's own timestamp if the header is short
    # or the value is not a sane date, so an odd sidecar never blocks a cleanup.
    function Get-DeletionTime {
        param([string]$InfoPath, [datetime]$Fallback)
        try {
            $bytes = [IO.File]::ReadAllBytes($InfoPath)
            if ($bytes.Length -ge 24) {
                $ft = [BitConverter]::ToInt64($bytes, 16)
                if ($ft -gt 0) {
                    $dt = [DateTime]::FromFileTime($ft)
                    if ($dt -gt ([DateTime]'1995-01-01') -and $dt -le (Get-Date).AddDays(1)) { return $dt }
                }
            }
        } catch { }
        return $Fallback
    }

    # Explorer caches each user's Recycle Bin item count and is never notified when
    # entries are removed on the filesystem, so the desktop icon can keep showing a
    # full bin long after it is empty. Deleting the emptied per-user folder clears
    # that cache. Windows recreates the folder on the user's next delete.
    function Reset-BinFolder {
        [CmdletBinding(SupportsShouldProcess=$true)]
        param([string]$Path, [string]$Who)
        $left = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -like '$R*' -or $_.Name -like '$I*' })
        if ($left.Count -gt 0) { return }
        if (-not $PSCmdlet.ShouldProcess($Who, 'Reset Recycle Bin folder')) { return }
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            Write-Output "$HEAD Reset the Recycle Bin folder for $Who so the desktop icon refreshes."
        } catch {
            # Cosmetic only, so this does not fail the run.
            Write-Output "$HEAD Could not reset the Recycle Bin folder for ${Who}: $($_.Exception.Message)"
        }
    }

    function Get-EntrySize {
        param([string]$Path)
        try {
            $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
            if ($item.PSIsContainer) {
                $sum = (Get-ChildItem -LiteralPath $Path -Force -Recurse -File -ErrorAction SilentlyContinue |
                        Measure-Object -Property Length -Sum).Sum
                if ($null -eq $sum) { return 0 }
                return [int64]$sum
            }
            return [int64]$item.Length
        } catch { return 0 }
    }

    $drives = if ($AllFixedDrives) {
        @(Get-Volume -ErrorAction SilentlyContinue |
          Where-Object { $_.DriveType -eq 'Fixed' -and $_.DriveLetter } |
          ForEach-Object { "$($_.DriveLetter):" })
    } else {
        @($env:SystemDrive)
    }

    $cutoff      = if ($OlderThanDays -gt 0) { (Get-Date).AddDays(-$OlderThanDays) } else { $null }
    $totalBytes  = 0
    $totalItems  = 0
    $totalKept   = 0

    foreach ($drive in $drives) {
        $binRoot = Join-Path $drive '$Recycle.Bin'
        if (-not (Test-Path -LiteralPath $binRoot)) {
            Write-Output "$HEAD $drive has no Recycle Bin folder. Skipping."
            continue
        }

        $allDirs = @(Get-ChildItem -LiteralPath $binRoot -Force -Directory -ErrorAction SilentlyContinue)
        $sidDirs = @($allDirs | Where-Object { $_.Name -like 'S-1-5-21-*' -or $_.Name -like 'S-1-12-1-*' })

        if ($sidDirs.Count -eq 0) {
            # Distinguish "the folder is genuinely empty" from "we could not read it",
            # because the two look identical in a console that only sees the summary.
            Write-Output "$HEAD $drive : no per-user Recycle Bin folders found ($($allDirs.Count) subfolder(s) visible under $binRoot)."
            continue
        }

        foreach ($sidDir in $sidDirs) {
            $sid = $sidDir.Name
            $who = try {
                (New-Object System.Security.Principal.SecurityIdentifier($sid)).Translate([System.Security.Principal.NTAccount]).Value
            } catch { $sid }

            # A user's own bin folder is readable only by that user, SYSTEM and
            # administrators. If enumeration is denied, that user's space was not
            # reclaimed, which almost always means the script is not running as
            # SYSTEM. Surface it rather than reporting a silent success.
            try {
                $entries = @(Get-ChildItem -LiteralPath $sidDir.FullName -Force -ErrorAction Stop |
                             Where-Object { $_.Name -like '$R*' })
            } catch {
                $script:FailureCount++
                Write-Output "$HEAD Cannot read the Recycle Bin for $who. Run this as SYSTEM. ($($_.CategoryInfo.Category))"
                continue
            }

            # Report every bin, including the empty ones. On a device that reclaimed
            # nothing this is the line that says whether the bin was reachable and
            # empty, or never reached at all.
            if ($entries.Count -eq 0) {
                Write-Output "$HEAD ${who} on ${drive}: bin is empty."
                if ($ResetShellIcon) { Reset-BinFolder -Path $sidDir.FullName -Who $who }
                continue
            }

            $userBytes = 0; $userItems = 0; $userKept = 0

            foreach ($entry in $entries) {
                # The sidecar shares the entry's suffix: $RABCDEF.txt <-> $IABCDEF.txt
                $infoPath = Join-Path $sidDir.FullName ('$I' + $entry.Name.Substring(2))
                $deleted  = if (Test-Path -LiteralPath $infoPath) {
                    Get-DeletionTime -InfoPath $infoPath -Fallback $entry.LastWriteTime
                } else {
                    $entry.LastWriteTime
                }

                if ($cutoff -and $deleted -gt $cutoff) { $userKept++; continue }

                $size = Get-EntrySize -Path $entry.FullName

                if ($PSCmdlet.ShouldProcess("$who : $($entry.Name)", 'Remove recycled item')) {
                    try {
                        Remove-Item -LiteralPath $entry.FullName -Recurse -Force -ErrorAction Stop
                        if (Test-Path -LiteralPath $infoPath) {
                            Remove-Item -LiteralPath $infoPath -Force -ErrorAction SilentlyContinue
                        }
                        $userBytes += $size
                        $userItems++
                    } catch {
                        # Usually a file still held open by a running process. Leave it
                        # and keep going; the next run will pick it up.
                        $script:FailureCount++
                        Write-Output "$HEAD Could not remove $($entry.Name) for ${who}: $($_.Exception.Message)"
                    }
                } else {
                    $userBytes += $size
                    $userItems++
                }
            }

            $keptNote = if ($userKept -gt 0) { ", $userKept left in place as newer than $OlderThanDays day(s)" } else { '' }
            Write-Output ("$HEAD {0} on {1}: {2} item(s), {3} MB{4}." -f $who, $drive, $userItems, [math]::Round($userBytes / 1MB, 2), $keptNote)

            # Reset-BinFolder checks for itself that nothing is left, so an age filter
            # that retained entries leaves the folder alone.
            if ($ResetShellIcon) { Reset-BinFolder -Path $sidDir.FullName -Who $who }

            $totalBytes += $userBytes
            $totalItems += $userItems
            $totalKept  += $userKept
        }
    }

    # Emitted as Key: value so a DEX sensor or custom attribute can parse them.
    Write-Output "$HEAD ItemsRemoved: $totalItems"
    Write-Output "$HEAD SpaceCleaned: $([math]::Round($totalBytes / 1MB, 2)) MB"
    if ($totalKept -gt 0) { Write-Output "$HEAD ItemsRetained: $totalKept" }
}

# -- entry point ---------------------------------------------------------------
# The param block sits inside the function deliberately. The Workspace ONE script
# engine does not recognise a param block at script scope, and $PSCmdlet is $null
# there, which makes every ShouldProcess call throw.
$SCRIPT_VERSION      = "2.2.0"
$script:FailureCount = 0
$RunEventId          = ([Random]::new()).Next(1000,9999)
$HEAD                = "`r`n[$RunEventId]"

Write-Output "[$RunEventId] Executing script, $SCRIPT_VERSION. Started @ '$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))'"

# Default to a LIVE run. Only an explicit, parseable "true" enables WhatIf, so a
# missing or malformed value can never turn remediation into a silent no-op.
$WhatIfPreference = $false
if ($env:WhatIf) {
    try   { $WhatIfPreference = [System.Convert]::ToBoolean($env:WhatIf) }
    catch { $WhatIfPreference = $false }
}

$OlderThanDays = 0
if ($env:OlderThanDays) {
    $parsed = 0
    if ([int]::TryParse($env:OlderThanDays, [ref]$parsed) -and $parsed -ge 0) { $OlderThanDays = $parsed }
}

$AllFixedDrives = $false
if ($env:AllFixedDrives) {
    try   { $AllFixedDrives = [System.Convert]::ToBoolean($env:AllFixedDrives) }
    catch { $AllFixedDrives = $false }
}

$ResetShellIcon = $false
if ($env:ResetShellIcon) {
    try   { $ResetShellIcon = [System.Convert]::ToBoolean($env:ResetShellIcon) }
    catch { $ResetShellIcon = $false }
}

# The account matters more here than for most remediations: the Recycle Bin is
# per-user, so a run that reclaims nothing is nearly always a run in the wrong
# context. State the context up front so the console output diagnoses itself.
$whoAmI = try { [System.Security.Principal.WindowsIdentity]::GetCurrent().Name } catch { 'unknown' }
Write-Output "$HEAD Running as $whoAmI. WhatIf=$WhatIfPreference, OlderThanDays=$OlderThanDays, AllFixedDrives=$AllFixedDrives, ResetShellIcon=$ResetShellIcon"

Start-ClearRecycleBin -OlderThanDays $OlderThanDays -AllFixedDrives:$AllFixedDrives -ResetShellIcon:$ResetShellIcon

if ($script:FailureCount -gt 0) { Exit 1 }
Exit 0
