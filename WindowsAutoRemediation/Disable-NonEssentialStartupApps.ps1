<#
.SYNOPSIS
    Disable-NonEssentialStartupApps -- Removes non-essential applications from Windows startup.

.DESCRIPTION
    Identifies and disables startup entries for known non-essential applications
    (gaming clients, media players, personal utilities) from the current user's
    registry Run key (HKCU). Only user-scope entries are modified automatically --
    machine-scope (HKLM) entries are reported but not touched.

    Disabling a startup entry does NOT uninstall the application; it simply
    prevents it from launching automatically at login.

    +------+------------------------------------------+--------------------+
    | Step | Name                                     | Remediates On      |
    +------+------------------------------------------+--------------------+
    |  1   | HKCU Run -- Gaming Clients               | Failed             |
    |  2   | HKCU Run -- Media & Entertainment        | Failed             |
    |  3   | HKCU Run -- Personal Utilities           | Failed             |
    |  4   | HKLM Run -- Non-Essential Entries (Audit)| Warning (audit)    |
    |  5   | Startup Folder -- User Scope             | Failed             |
    +------+------------------------------------------+--------------------+

    Each step returns @{ Status = 'Passed'|'Warning'|'Failed'; Message = '...' }
    Resolution removes the registry Run value or shortcut; errors are captured
    and reported at the end.

.NOTES
    Script Name  : Disable-NonEssentialStartupApps.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : User (HKCU modifications) -- run as the logged-on user
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-07-10
    Timeout      : 30 seconds

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

# -- Non-Essential Application Lists ------------------------------------------
# Matched against the registry value name (the label, not the path).
# Values are compared case-insensitively using -match for partial matching.

$GamingClients = @(
    'Steam',
    'EpicGamesLauncher',
    'Epic Games Launcher',
    'GOGGalaxy',
    'GOG Galaxy',
    'EADesktop',
    'EA App',
    'EABackgroundService',
    'Battle.net',
    'Battlenet',
    'Uplay',
    'UbisoftConnect',
    'Ubisoft Connect',
    'RockstarGamesLauncher',
    'Rockstar Games Launcher',
    'ItchioApp',
    'itch',
    'Roblox',
    'Discord'           # personal -- org-deployed Discord is typically HKLM
)

$MediaEntertainment = @(
    'Spotify',
    'SpotifyWebHelper',
    'iTunesHelper',
    'iTunes',
    'ApplePushNotification',
    'AppleSoftwareUpdate',
    'QuickTime',
    'VLC media player',
    'AmazonMusic',
    'TidalHifi',
    'TIDAL',
    'Deezer',
    'Plex Media Player',
    'PlexHTPC',
    'kodi',
    'VoodoShield'        # gaming overlay, not security product
)

$PersonalUtilities = @(
    'LogiOptions',
    'LGHUB',
    'Logitech G HUB',
    'RazerSynapse',
    'Razer Synapse',
    'CorsairHID',
    'iCUE',
    'SteelSeriesGG',
    'SteelSeries GG',
    'NZXT CAM',
    'NZXTCam',
    'NahimicSvc',       # Nahimic audio overlay (gaming boards) -- not a system service
    'MSI Afterburner',
    'MSIAfterburner',
    'RivaTuner',
    'RTSS',
    'CCleaner',
    'CCleanerBrowser',
    'Avast Browser',
    'AvastBrowser',
    'WinZip',
    'Dropbox'           # personal installs -- org-managed Dropbox is typically HKLM
)

# All non-essential names as a single flat list for convenience
$AllNonEssential = $GamingClients + $MediaEntertainment + $PersonalUtilities

# Helper: returns all HKCU Run values whose name matches any entry in $nameList
function Get-MatchingRunValues {
    param([string]$RegPath, [string[]]$NameList)
    $found = @()
    $runValues = Get-ItemProperty -Path $RegPath -ErrorAction SilentlyContinue
    if (-not $runValues) { return $found }
    foreach ($prop in ($runValues.PSObject.Properties | Where-Object { $_.MemberType -eq 'NoteProperty' -and $_.Name -notmatch '^PS' })) {
        foreach ($name in $NameList) {
            if ($prop.Name -match [regex]::Escape($name)) {
                $found += $prop.Name
                break
            }
        }
    }
    return $found
}

# -- Step Definitions ----------------------------------------------------------
$hkcuRunPath   = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$hklmRunPath   = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'
$startupFolder = [System.Environment]::GetFolderPath('Startup')

$Steps = @(

    @{
        Name             = 'HKCU Run - Gaming Clients'
        Order            = 1
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            $found = Get-MatchingRunValues -RegPath $hkcuRunPath -NameList $GamingClients
            if ($found.Count -gt 0) {
                return @{ Status = 'Failed'; Message = "Gaming client startup entries found: $($found -join ', ')" }
            }
            return @{ Status = 'Passed'; Message = 'No gaming client startup entries in HKCU Run' }
        }
        ResolutionScript = {
            $found = Get-MatchingRunValues -RegPath $hkcuRunPath -NameList $GamingClients
            foreach ($entry in $found) {
                Remove-ItemProperty -Path $hkcuRunPath -Name $entry -Force -ErrorAction SilentlyContinue
            }
        }
    },

    @{
        Name             = 'HKCU Run - Media & Entertainment'
        Order            = 2
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            $found = Get-MatchingRunValues -RegPath $hkcuRunPath -NameList $MediaEntertainment
            if ($found.Count -gt 0) {
                return @{ Status = 'Failed'; Message = "Media app startup entries found: $($found -join ', ')" }
            }
            return @{ Status = 'Passed'; Message = 'No media app startup entries in HKCU Run' }
        }
        ResolutionScript = {
            $found = Get-MatchingRunValues -RegPath $hkcuRunPath -NameList $MediaEntertainment
            foreach ($entry in $found) {
                Remove-ItemProperty -Path $hkcuRunPath -Name $entry -Force -ErrorAction SilentlyContinue
            }
        }
    },

    @{
        Name             = 'HKCU Run - Personal Utilities'
        Order            = 3
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            $found = Get-MatchingRunValues -RegPath $hkcuRunPath -NameList $PersonalUtilities
            if ($found.Count -gt 0) {
                return @{ Status = 'Failed'; Message = "Personal utility startup entries found: $($found -join ', ')" }
            }
            return @{ Status = 'Passed'; Message = 'No personal utility startup entries in HKCU Run' }
        }
        ResolutionScript = {
            $found = Get-MatchingRunValues -RegPath $hkcuRunPath -NameList $PersonalUtilities
            foreach ($entry in $found) {
                Remove-ItemProperty -Path $hkcuRunPath -Name $entry -Force -ErrorAction SilentlyContinue
            }
        }
    },

    @{
        Name             = 'HKLM Run - Non-Essential Entries (Audit)'
        Order            = 4
        Enabled          = $true
        ResolveOnWarning = $false  # HKLM is not auto-modified -- requires admin review
        DetectionScript  = {
            $found = Get-MatchingRunValues -RegPath $hklmRunPath -NameList $AllNonEssential
            if ($found.Count -gt 0) {
                return @{
                    Status  = 'Warning'
                    Message = "Machine-scope non-essential startup entries found (admin review required): $($found -join ', ')"
                }
            }
            return @{ Status = 'Passed'; Message = 'No non-essential entries in HKLM Run' }
        }
        ResolutionScript = $null   # ADMIN action only
    },

    @{
        Name             = 'Startup Folder - User Scope'
        Order            = 5
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            if (-not (Test-Path $startupFolder)) {
                return @{ Status = 'Passed'; Message = 'User startup folder does not exist' }
            }
            $shortcuts = Get-ChildItem -Path $startupFolder -Filter '*.lnk' -ErrorAction SilentlyContinue
            if (-not $shortcuts) {
                return @{ Status = 'Passed'; Message = 'No shortcuts in user startup folder' }
            }
            $nonEssential = @()
            foreach ($sc in $shortcuts) {
                foreach ($name in $AllNonEssential) {
                    if ($sc.BaseName -match [regex]::Escape($name)) {
                        $nonEssential += $sc.Name
                        break
                    }
                }
            }
            if ($nonEssential.Count -gt 0) {
                return @{ Status = 'Failed'; Message = "Non-essential startup shortcuts found: $($nonEssential -join ', ')" }
            }
            return @{ Status = 'Passed'; Message = "Startup folder clean ($($shortcuts.Count) shortcut(s), none matched non-essential list)" }
        }
        ResolutionScript = {
            $shortcuts = Get-ChildItem -Path $startupFolder -Filter '*.lnk' -ErrorAction SilentlyContinue
            foreach ($sc in $shortcuts) {
                foreach ($name in $AllNonEssential) {
                    if ($sc.BaseName -match [regex]::Escape($name)) {
                        Remove-Item -Path $sc.FullName -Force -ErrorAction SilentlyContinue
                        break
                    }
                }
            }
        }
    }
)

# -- Engine --------------------------------------------------------------------
$activeSteps = $Steps | Where-Object { $_.Enabled } | Sort-Object Order

$results = New-Object 'System.Collections.Generic.List[PSCustomObject]'

Write-Host "`n-- Disable-NonEssentialStartupApps -----------------------------" -ForegroundColor Cyan
Write-Host "   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')   Steps: $($activeSteps.Count)"
Write-Host '----------------------------------------------------------------' -ForegroundColor Cyan

foreach ($step in $activeSteps) {

    $status     = 'Failed'
    $message    = 'Detection script did not return a result.'
    $remediated = $false
    $remError   = ''

    # -- Detection ------------------------------------------------------------
    try {
        $result  = & $step.DetectionScript
        $status  = $result.Status
        $message = $result.Message
    } catch {
        $status  = 'Failed'
        $message = "Detection exception: $($_.Exception.Message)"
    }

    # -- Remediation ----------------------------------------------------------
    $shouldRemediate = ($status -eq 'Failed') -or
                       ($status -eq 'Warning' -and $step.ResolveOnWarning)

    if ($shouldRemediate -and $step.ResolutionScript) {
        try {
            & $step.ResolutionScript | Out-Null
            $remediated = $true
        } catch {
            $remError = $_.Exception.Message
        }
    }

    # -- Output ---------------------------------------------------------------
    $color = switch ($status) {
        'Passed'  { 'Green'  }
        'Warning' { 'Yellow' }
        'Failed'  { 'Red'    }
        default   { 'White'  }
    }
    $remNote = if ($remediated)   { '  -> Remediation ran' }
               elseif ($remError) { "  -> Remediation ERROR: $remError" }
               else               { '' }

    Write-Host "`n  [$($status.PadRight(7))] $($step.Name): $message$remNote" -ForegroundColor $color

    $results.Add([PSCustomObject]@{
        Order      = $step.Order
        Name       = $step.Name
        Status     = $status
        Message    = $message
        Remediated = $remediated
        RemError   = $remError
    })
}

# -- Summary -------------------------------------------------------------------
$passed   = ($results | Where-Object { $_.Status -eq 'Passed'  }).Count
$warnings = ($results | Where-Object { $_.Status -eq 'Warning' }).Count
$failed   = ($results | Where-Object { $_.Status -eq 'Failed'  }).Count
$remCount = ($results | Where-Object { $_.Remediated }).Count

Write-Host "`n----------------------------------------------------------------" -ForegroundColor Cyan
Write-Host "  Passed: $passed  |  Warnings: $warnings  |  Failed: $failed  |  Remediations run: $remCount"
Write-Host "`n----------------------------------------------------------------" -ForegroundColor Cyan
Write-Host ''

if ($failed -gt 0) { exit 1 }
exit 0
