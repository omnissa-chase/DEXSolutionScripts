<#
.SYNOPSIS
    Invoke-RemediateSysMain -- Detects and remediates a stopped or disabled SysMain service.

.DESCRIPTION
    Checks whether the SysMain (Superfetch) service is running and set to start
    automatically. SysMain manages memory pre-fetching and the working-set
    manager; when it is stopped or disabled, memory is not proactively managed,
    which degrades application launch performance and can cause elevated commit
    charge over time.

    If the service is stopped or its startup type is Disabled, this script sets
    the startup type to Automatic and starts the service.

    Note: on SSD-only devices some administrators intentionally disable SysMain.
    If this script is deployed selectively, apply targeting rules to exclude
    those devices or set Enabled = $false for affected groups.

    Designed for deployment as a Workspace ONE MDM remediation script or
    standalone admin tool.

.NOTES
    Script Name  : Invoke-RemediateSysMain.ps1
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
    $svc = Get-Service -Name SysMain -ErrorAction Stop

    if ($svc.Status -eq 'Running') {
        $status  = 'Passed'
        $message = "SysMain is running (StartType: $($svc.StartType))"
    } elseif ($svc.StartType -eq 'Disabled') {
        $status  = 'Failed'
        $message = "SysMain is disabled. Setting to Automatic and starting."
    } else {
        $status  = 'Failed'
        $message = "SysMain is $($svc.Status) (StartType: $($svc.StartType)). Starting service."
    }
} catch {
    $status  = 'Failed'
    $message = "Detection exception: $($_.Exception.Message)"
}

# -- Remediation --------------------------------------------------------------
if ($status -eq 'Failed') {
    try {
        Set-Service   -Name SysMain -StartupType Automatic -ErrorAction Stop
        Start-Service -Name SysMain                        -ErrorAction Stop
        $remediated = $true
    } catch {
        $remError = $_.Exception.Message
    }
}

# -- Output -------------------------------------------------------------------
$color   = switch ($status) { 'Passed' { 'Green' } 'Warning' { 'Yellow' } 'Failed' { 'Red' } default { 'White' } }
$tag     = if ($remediated) { '[Remediated]' } else { "[$status]" }
$remNote = if ($remError)   { "  -> Remediation ERROR: $remError" } else { '' }

Write-Host "`n-- Invoke-RemediateSysMain -------------------------------------" -ForegroundColor Cyan
Write-Host "   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host "----------------------------------------------------------------" -ForegroundColor Cyan
Write-Host "`n  $tag $message" -ForegroundColor $color
if ($remNote) { Write-Host $remNote -ForegroundColor Yellow }
Write-Host ''

# -- Registry Reporting -------------------------------------------------------
$regPath = 'HKLM:\Software\AirWatch\Extension\DEXRecords\MemoryErrors\SysMain'
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
