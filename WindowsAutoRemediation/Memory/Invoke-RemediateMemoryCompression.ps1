<#
.SYNOPSIS
    Invoke-RemediateMemoryCompression -- Detects and remediates disabled memory compression.

.DESCRIPTION
    Checks whether the Windows Memory Compression feature is enabled via the
    MMAgent (Memory Manager Agent). Memory Compression reduces physical memory
    pressure by compressing rarely-accessed pages in RAM instead of paging them
    to disk, improving responsiveness on memory-constrained devices.

    If memory compression is disabled, this script re-enables it with
    Enable-MMAgent -MemoryCompression.

    Note: changes to MMAgent take effect without a reboot but may take a short
    time to stabilize as the compressor populates its working set.

    Designed for deployment as a Workspace ONE MDM remediation script or
    standalone admin tool.

.NOTES
    Script Name  : Invoke-RemediateMemoryCompression.ps1
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

# -- Detection ----------------------------------------------------------------
$status     = 'Passed'
$message    = ''
$remediated = $false
$remError   = ''

try {
    $agent = Get-MMAgent -ErrorAction Stop

    if ($agent.MemoryCompression) {
        $status  = 'Passed'
        $message = 'Memory compression is enabled.'
    } else {
        $status  = 'Warning'
        $message = 'Memory compression is disabled. Enabling now.'
    }
} catch {
    $status  = 'Failed'
    $message = "Detection exception: $($_.Exception.Message)"
}

# -- Remediation --------------------------------------------------------------
# Resolve on Warning -- disabled compression is always correctable in software.
if ($status -eq 'Warning' -or $status -eq 'Failed') {
    try {
        Enable-MMAgent -MemoryCompression -ErrorAction Stop
        $remediated = $true
    } catch {
        $remError = $_.Exception.Message
    }
}

# -- Output -------------------------------------------------------------------
$color   = switch ($status) { 'Passed' { 'Green' } 'Warning' { 'Yellow' } 'Failed' { 'Red' } default { 'White' } }
$tag     = if ($remediated) { '[Remediated]' } else { "[$status]" }
$remNote = if ($remError)   { "  -> Remediation ERROR: $remError" } else { '' }

Write-Host "`n-- Invoke-RemediateMemoryCompression ---------------------------" -ForegroundColor Cyan
Write-Host "   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host "----------------------------------------------------------------" -ForegroundColor Cyan
Write-Host "`n  $tag $message" -ForegroundColor $color
if ($remNote) { Write-Host $remNote -ForegroundColor Yellow }
Write-Host ''

# -- Registry Reporting -------------------------------------------------------
$regPath = 'HKLM:\Software\AirWatch\Extension\DEXRecords\MemoryErrors\MemoryCompression'
try {
    if (-not (Test-Path $regPath)) {
        New-Item -Path $regPath -Force -ErrorAction Stop | Out-Null
    }

    $regStatus = if ($remediated) { 'Remediated' } else { $status }
    Set-ItemProperty -Path $regPath -Name 'LastScanTime' -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') -Type String
    Set-ItemProperty -Path $regPath -Name 'Status'       -Value $regStatus -Type String
    Set-ItemProperty -Path $regPath -Name 'Message'      -Value $message   -Type String
    if ($remError) {
        Set-ItemProperty -Path $regPath -Name 'RemediationError' -Value $remError -Type String
    }

    Write-Host "  [Registry] Results written to $regPath" -ForegroundColor DarkCyan
} catch {
    Write-Host "  [Registry] Write failed: $($_.Exception.Message)" -ForegroundColor Yellow
}

# -- Exit ---------------------------------------------------------------------
if ($status -ne 'Passed' -and -not $remediated) { exit 1 }
exit 0
