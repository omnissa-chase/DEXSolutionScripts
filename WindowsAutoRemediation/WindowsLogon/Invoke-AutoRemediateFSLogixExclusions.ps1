#Requires -Version 5.1
<#
.SYNOPSIS
    Applies Microsoft's documented Windows Defender exclusions for FSLogix profile
    containers -- the single most common, and most avoidable, cause of slow FSLogix
    attach at logon.

.DESCRIPTION
    Real-time antivirus scanning of an open VHD(X) handle is the textbook cause of a
    slow or hanging FSLogix profile attach: every read/write inside the container gets
    re-scanned as if it were a new file. Microsoft publishes a fixed exclusion list for
    exactly this reason. This script applies that list to Microsoft Defender only.

    Does nothing, and reports so, on a device where FSLogix is not installed. Does
    nothing, and reports so, on a device where Defender is not the active antivirus --
    a third-party AV needs the same exclusions configured through its own console or
    policy, which this script cannot do generically (see AntiVirusResolutionScripts/
    for vendor-specific scripts). Applying exclusions to a passive, non-authoritative
    Defender instance is harmless, so this only skips when the Defender cmdlets
    themselves are unavailable.

    Profile container share paths are not guessed or hard-coded -- they are read
    directly from FSLogix's own configuration (HKLM:\SOFTWARE\FSLogix\Profiles and
    \ODFC, value VHDLocations), so the exclusion list stays correct as that
    configuration changes.

    +------+---------------------------------+--------------------------------------+
    | Step | Name                            | Remediation                          |
    +------+---------------------------------+--------------------------------------+
    |  1   | FSLogix Process Exclusions      | Add-MpPreference -ExclusionProcess   |
    |  2   | FSLogix Path Exclusions         | Add-MpPreference -ExclusionPath      |
    |  3   | FSLogix VHD Extension Exclusion | Add-MpPreference -ExclusionExtension |
    +------+---------------------------------+--------------------------------------+

    This script only ever adds exclusions. It never removes one, even one this script
    did not add -- a narrower exclusion list may be intentional, and this is not the
    place to second-guess it.

    Results are written to HKLM:\Software\AirWatch\Extensions\FSLogix\Remediation.

.NOTES
    Script Name  : Invoke-AutoRemediateFSLogixExclusions.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-05
    Timeout      : 30 seconds

    Environment variables:
      WhatIf = true    Dry run. Absent/unparseable => live run.

    Reference: Microsoft Learn -- "Configuration Reference for Microsoft FSLogix Apps",
    section "Antivirus Exclusions".

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param()

$SCRIPT_VERSION = "1.0.0"
$RegPath        = "HKLM:\Software\AirWatch\Extensions\FSLogix\Remediation"
$LogPath        = "$env:SystemRoot\Temp\UEM_AutoRemediateFSLogixExclusions.log"

# -- WhatIf bridge -------------------------------------------------------------
# UEM cannot set $WhatIfPreference directly. Bridge it from an environment
# variable. Absent, empty, or unparseable => $false (live run).
$WhatIfPreference = $false
if ($env:WhatIf) {
    try   { $WhatIfPreference = [System.Convert]::ToBoolean($env:WhatIf) }
    catch { $WhatIfPreference = $false }
}

# -- Run header ----------------------------------------------------------------
$RunEventId = ([Random]::new()).Next(1000, 9999)
Write-Host "[$RunEventId] Executing Invoke-AutoRemediateFSLogixExclusions, $SCRIPT_VERSION. Started @ '$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))'  WhatIf=$WhatIfPreference"
$HEAD = "`r`n[$RunEventId]"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    # -WhatIf:$false so a dry run is still recorded; the log is evidence, not state.
    "[$timestamp] [$RunEventId] [$Level] $Message" |
        Out-File -FilePath $LogPath -Append -Encoding UTF8 -WhatIf:$false -ErrorAction SilentlyContinue
}

# -- Pre-flight: is there anything for this script to do? ----------------------
# The whole script is meaningless without FSLogix, so this is a hard gate rather
# than one more Steps entry -- there is nothing else worth checking without it.
$fslogixService = Get-Service -Name 'frxsvc' -ErrorAction SilentlyContinue
if (-not $fslogixService) {
    Write-Host "$HEAD FSLogix is not installed on this device (frxsvc service not found). Nothing to do." -ForegroundColor Yellow
    Write-Log 'FSLogix not installed. Exiting without changes.'
    exit 0
}

if (-not (Get-Command -Name Add-MpPreference -ErrorAction SilentlyContinue)) {
    Write-Host "$HEAD Windows Defender PowerShell cmdlets are not available on this device. A third-party antivirus needs these exclusions configured through its own console or policy -- out of scope for this script." -ForegroundColor Yellow
    Write-Log 'Add-MpPreference unavailable (Defender module missing or AV replaced). Exiting without changes.'
    exit 0
}

# -- Profile container locations, read from FSLogix's own configuration -------
# VHDLocations is a REG_MULTI_SZ. Both Profile Containers and Office Containers
# (ODFC) can point at different shares, so both are checked.
function Get-FSLogixVhdLocations {
    $locations = @()
    foreach ($key in @('HKLM:\SOFTWARE\FSLogix\Profiles', 'HKLM:\SOFTWARE\FSLogix\ODFC')) {
        $prop = Get-ItemProperty -Path $key -Name 'VHDLocations' -ErrorAction SilentlyContinue
        if ($prop -and $prop.VHDLocations) {
            $locations += @($prop.VHDLocations) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        }
    }
    return $locations | Select-Object -Unique
}

$vhdLocations = Get-FSLogixVhdLocations
Write-Log "Discovered $($vhdLocations.Count) FSLogix VHD location(s): $($vhdLocations -join ', ')"

# -- Required exclusions, per Microsoft's published FSLogix guidance -----------
$RequiredProcesses = @(
    "$env:ProgramFiles\FSLogix\Apps\frxccd.exe"
    "$env:ProgramFiles\FSLogix\Apps\frxccds.exe"
    "$env:ProgramFiles\FSLogix\Apps\frxsvc.exe"
)

$RequiredPaths = @(
    "$env:ProgramData\FSLogix\Cache\*"
    "$env:ProgramData\FSLogix\Proxy\*"
    "$env:TEMP\*.VHD"
    "$env:TEMP\*.VHDX"
    "$env:SystemRoot\Temp\*.VHD"
    "$env:SystemRoot\Temp\*.VHDX"
) + ($vhdLocations | ForEach-Object { "$($_.TrimEnd('\'))\*.VHD", "$($_.TrimEnd('\'))\*.VHDX" })

$RequiredExtensions = @('VHD', 'VHDX')

# -- Step Definitions -----------------------------------------------------------
# Only supported fields: Name, Order, Enabled, ResolveOnWarning,
#                        DetectionScript, ResolutionScript
$Steps = @(

    @{
        Name             = 'FSLogix Process Exclusions'
        Order            = 1
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            $current = (Get-MpPreference -ErrorAction SilentlyContinue).ExclusionProcess
            $missing = $RequiredProcesses | Where-Object { $current -notcontains $_ }
            if ($missing) {
                return @{ Status = 'Failed'; Message = "Missing: $($missing -join ', ')" }
            }
            return @{ Status = 'Passed'; Message = "All $($RequiredProcesses.Count) process exclusions present" }
        }
        ResolutionScript = {
            $current = (Get-MpPreference -ErrorAction SilentlyContinue).ExclusionProcess
            $missing = $RequiredProcesses | Where-Object { $current -notcontains $_ }
            if ($missing) { Add-MpPreference -ExclusionProcess $missing -ErrorAction Stop }
        }
    },

    @{
        Name             = 'FSLogix Path Exclusions'
        Order            = 2
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            $current = (Get-MpPreference -ErrorAction SilentlyContinue).ExclusionPath
            $missing = $RequiredPaths | Where-Object { $current -notcontains $_ }
            if ($missing) {
                return @{ Status = 'Failed'; Message = "Missing: $($missing -join ', ')" }
            }
            return @{ Status = 'Passed'; Message = "All $($RequiredPaths.Count) path exclusions present" }
        }
        ResolutionScript = {
            $current = (Get-MpPreference -ErrorAction SilentlyContinue).ExclusionPath
            $missing = $RequiredPaths | Where-Object { $current -notcontains $_ }
            if ($missing) { Add-MpPreference -ExclusionPath $missing -ErrorAction Stop }
        }
    },

    @{
        Name             = 'FSLogix VHD Extension Exclusions'
        Order            = 3
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            $current = (Get-MpPreference -ErrorAction SilentlyContinue).ExclusionExtension
            $missing = $RequiredExtensions | Where-Object { $current -notcontains $_ }
            if ($missing) {
                return @{ Status = 'Failed'; Message = "Missing: $($missing -join ', ')" }
            }
            return @{ Status = 'Passed'; Message = "All $($RequiredExtensions.Count) extension exclusions present" }
        }
        ResolutionScript = {
            $current = (Get-MpPreference -ErrorAction SilentlyContinue).ExclusionExtension
            $missing = $RequiredExtensions | Where-Object { $current -notcontains $_ }
            if ($missing) { Add-MpPreference -ExclusionExtension $missing -ErrorAction Stop }
        }
    }
)

# -- Execution Engine ------------------------------------------------------------
$activeSteps = $Steps |
    Where-Object { $_.Enabled } |
    Sort-Object   { [int]$_.Order }

$results = New-Object 'System.Collections.Generic.List[PSCustomObject]'

Write-Host "`n-- Invoke-AutoRemediateFSLogixExclusions --------------------------" -ForegroundColor Cyan
Write-Host "   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')   Steps: $($activeSteps.Count)"
Write-Host '--------------------------------------------------------------------' -ForegroundColor Cyan

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

    # -- Remediation ------------------------------------------------------------
    $shouldRemediate = ($status -eq 'Failed') -or
                       ($status -eq 'Warning' -and $step.ResolveOnWarning)

    if ($shouldRemediate -and $step.ResolutionScript) {
        if ($PSCmdlet.ShouldProcess($step.Name, 'Apply FSLogix exclusion(s)')) {
            try {
                & $step.ResolutionScript | Out-Null
                $remediated = $true
            } catch {
                $remError = $_.Exception.Message
            }
        }
    }

    # -- Output -------------------------------------------------------------------
    $color = switch ($status) {
        'Passed'  { 'Green'  }
        'Warning' { 'Yellow' }
        'Failed'  { 'Red'    }
        default   { 'White'  }
    }
    $remNote = if ($remediated)   { '  -> Remediation applied' }
               elseif ($remError) { "  -> Remediation ERROR: $remError" }
               else               { '' }

    Write-Host "`n  [$($status.PadRight(7))] $($step.Name): $message$remNote" -ForegroundColor $color
    Write-Log "$($step.Name): $status - $message$remNote"

    $results.Add([PSCustomObject]@{
        Order      = $step.Order
        Name       = $step.Name
        Status     = $status
        Message    = $message
        Remediated = $remediated
        RemError   = $remError
    })
}

# -- Summary -----------------------------------------------------------------
$passed   = ($results | Where-Object { $_.Status -eq 'Passed'  }).Count
$warnings = ($results | Where-Object { $_.Status -eq 'Warning' }).Count
$failed   = ($results | Where-Object { $_.Status -eq 'Failed'  }).Count
$remCount = ($results | Where-Object { $_.Remediated }).Count
$remErrs  = ($results | Where-Object { $_.RemError }).Count

Write-Host "`n--------------------------------------------------------------------" -ForegroundColor Cyan
Write-Host "  Passed: $passed  |  Warnings: $warnings  |  Failed: $failed  |  Remediations applied: $remCount"
Write-Host "--------------------------------------------------------------------`n" -ForegroundColor Cyan
Write-Log "Summary: Passed=$passed Warnings=$warnings Failed=$failed RemediationsApplied=$remCount RemediationErrors=$remErrs"

# -- Registry Reporting --------------------------------------------------------
# Skipped entirely on a WhatIf run -- a dry run must not claim a remediation state
# that was never actually applied.
if (-not $WhatIfPreference) {
    try {
        if (-not (Test-Path $RegPath)) {
            New-Item -Path $RegPath -Force -ErrorAction Stop | Out-Null
        }
        Set-ItemProperty -Path $RegPath -Name 'LastRun'            -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') -Type String
        Set-ItemProperty -Path $RegPath -Name 'ScriptVersion'      -Value $SCRIPT_VERSION -Type String
        Set-ItemProperty -Path $RegPath -Name 'Passed'             -Value $passed   -Type DWord
        Set-ItemProperty -Path $RegPath -Name 'Warnings'           -Value $warnings -Type DWord
        Set-ItemProperty -Path $RegPath -Name 'Failed'             -Value $failed   -Type DWord
        Set-ItemProperty -Path $RegPath -Name 'RemediationsRun'    -Value $remCount -Type DWord
        Set-ItemProperty -Path $RegPath -Name 'RemediationErrors'  -Value $remErrs  -Type DWord
        Write-Log "Results cached to $RegPath"
    } catch {
        Write-Log "Registry cache write failed: $($_.Exception.Message)" 'WARN'
    }
} else {
    Write-Log 'WhatIf run -- registry cache left untouched.'
}

exit $(if ($remErrs -gt 0) { 1 } else { 0 })
