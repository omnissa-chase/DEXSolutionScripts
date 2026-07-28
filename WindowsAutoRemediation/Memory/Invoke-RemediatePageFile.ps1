<#
.SYNOPSIS
    Invoke-RemediatePageFile -- Detects and remediates page file misconfiguration.

.DESCRIPTION
    Checks whether the Windows page file is manually configured (fixed size) and
    whether current usage has exceeded the configured threshold. If the page file
    is not system-managed, resets it to automatic management via CIM.

    High usage on an already system-managed page file is reported as informational
    -- no software fix is possible; the signal should prompt a RAM upgrade review.

    Note: page file size changes take effect after the next reboot.

    Designed for deployment as a Workspace ONE MDM remediation script or
    standalone admin tool.

.PARAMETER PageFileUsageFailPercent
    Usage percentage at which a manually-configured page file is considered
    critically undersized and a reset to system-managed is attempted.
    Default: 80.  Override via $env:PageFileUsageFailPercent.

.NOTES
    Script Name  : Invoke-RemediatePageFile.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-07-28
    Timeout      : 30 seconds

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

param(
    [int]$PageFileUsageFailPercent = $(if ($env:PageFileUsageFailPercent) { [int]$env:PageFileUsageFailPercent } else { 80 })
)

# -- Detection ----------------------------------------------------------------
$status     = 'Passed'
$message    = ''
$remediated = $false
$remError   = ''
$cs         = $null

try {
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop

    # Peak usage across all active page files (Win32_PageFileUsage values are in MB)
    $maxPct    = 0
    $usageDesc = 'no active page file data'
    $usages    = Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue
    foreach ($pf in $usages) {
        if ($pf.AllocatedBaseSize -gt 0) {
            $pct = [math]::Round(($pf.CurrentUsage / $pf.AllocatedBaseSize) * 100, 1)
            if ($pct -gt $maxPct) {
                $maxPct    = $pct
                $usageDesc = "$($pf.CurrentUsage)MB / $($pf.AllocatedBaseSize)MB (${pct}%)"
            }
        }
    }

    if (-not $cs.AutomaticManagedPagefile) {
        # Manually configured -- critical if at or near the threshold
        if ($maxPct -ge $PageFileUsageFailPercent) {
            $status  = 'Failed'
            $message = "Page file is manually configured and near capacity: $usageDesc. Resetting to system-managed."
        } else {
            $status  = 'Warning'
            $message = "Page file is manually configured ($usageDesc). System-managed is recommended."
        }
    } else {
        # System-managed: high usage is informational only
        if ($maxPct -ge $PageFileUsageFailPercent) {
            $status  = 'Warning'
            $message = "Page file is system-managed but usage is high: $usageDesc. Consider adding physical RAM."
        } else {
            $status  = 'Passed'
            $message = "Page file is system-managed, $usageDesc."
        }
    }
} catch {
    $status  = 'Failed'
    $message = "Detection exception: $($_.Exception.Message)"
}

# -- Remediation --------------------------------------------------------------
# Only attempts a fix when the page file is manually configured AND at threshold.
# Warning cases (manual-but-OK, or system-managed-but-high) are advisory only.
if ($status -eq 'Failed' -and $cs -and -not $cs.AutomaticManagedPagefile) {
    try {
        $cs | Set-CimInstance -Property @{ AutomaticManagedPagefile = $true } -ErrorAction Stop
        $remediated = $true
    } catch {
        $remError = $_.Exception.Message
    }
}

# -- Output -------------------------------------------------------------------
$color   = switch ($status) { 'Passed' { 'Green' } 'Warning' { 'Yellow' } 'Failed' { 'Red' } default { 'White' } }
$tag     = if ($remediated) { '[Remediated]' } else { "[$status]" }
$remNote = if ($remediated)   { '  -> Reboot recommended for page file changes to take full effect.' }
           elseif ($remError) { "  -> Remediation ERROR: $remError" }
           else               { '' }

Write-Host "`n-- Invoke-RemediatePageFile ------------------------------------" -ForegroundColor Cyan
Write-Host "   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host "----------------------------------------------------------------" -ForegroundColor Cyan
Write-Host "`n  $tag $message" -ForegroundColor $color
if ($remNote) { Write-Host $remNote -ForegroundColor Yellow }
Write-Host ''

# -- Registry Reporting -------------------------------------------------------
$regPath = 'HKLM:\Software\AirWatch\Extension\DEXRecords\MemoryErrors\PageFile'
try {
    if (-not (Test-Path $regPath)) {
        New-Item -Path $regPath -Force -ErrorAction Stop | Out-Null
    }

    $regStatus = if ($remediated) { 'Remediated' } else { $status }
    Set-ItemProperty -Path $regPath -Name 'LastScanTime'      -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') -Type String
    Set-ItemProperty -Path $regPath -Name 'Status'            -Value $regStatus -Type String
    Set-ItemProperty -Path $regPath -Name 'Message'           -Value $message   -Type String
    if ($remediated) {
        Set-ItemProperty -Path $regPath -Name 'RebootRequired' -Value 'True'    -Type String
    }
    if ($remError) {
        Set-ItemProperty -Path $regPath -Name 'RemediationError' -Value $remError -Type String
    }

    Write-Host "  [Registry] Results written to $regPath" -ForegroundColor DarkCyan
} catch {
    Write-Host "  [Registry] Write failed: $($_.Exception.Message)" -ForegroundColor Yellow
}

# -- Exit ---------------------------------------------------------------------
# Exit 1 if an issue was detected but no remediation could be applied.
if ($status -ne 'Passed' -and -not $remediated) { exit 1 }
exit 0
