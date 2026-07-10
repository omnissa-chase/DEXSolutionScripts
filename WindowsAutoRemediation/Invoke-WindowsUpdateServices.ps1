<#
.SYNOPSIS
    Restarts Windows Update and related services to resolve stalled or broken
    update states.

.PARAMETER ForceRestart
    When $true (default), the service is stopped and restarted even if it is
    already in a Running state. Set to $false to skip services that are
    already running.

.NOTES
    Script Name  : Invoke-WindowsUpdateServices.ps1
    Version      : 1.6.1.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-07-10
    Timeout      : 60 seconds

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

# ── Configuration ─────────────────────────────────────────────────────────────

$SCRIPT_VERSION = "1.6.1.0"

# Set to $true to stop/start the service even if it is already running.
# Set to $false to skip services that are already in a Running state.
$ForceRestart = $true

# Set to $true to log actions without actually stopping or starting services.
$WhatIfPreference = $false

# Services to remediate. Add additional service names to this list as needed.
# Common Windows Update related services:
#   wuauserv    — Windows Update Agent (core update service)
#   bits        — Background Intelligent Transfer Service (download engine)
#   cryptsvc    — Cryptographic Services (certificate validation for updates)
#   msiserver   — Windows Installer (required for update package installation)
$services = @("wuauserv")

# ── Execution ─────────────────────────────────────────────────────────────────

# Generate a random 4-digit ID to correlate all log lines from this run
$RunEventId = ([Random]::new()).Next(1000, 9999)

Write-Host "`n[$RunEventId] Invoke-WindowsUpdateServices v$SCRIPT_VERSION  Started @ $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"

# $HEAD prefix is prepended to every log line for easy grep/correlation
$HEAD = "`n[$RunEventId]"

$ServiceTotal   = 0
$ServiceStarted = 0

ForEach ($service in $services) {

    $svc = Get-Service -Name $service -ErrorAction SilentlyContinue

    If ($svc) {
        $ServiceTotal++

        If ($svc.Status -ne 'Running' -or $ForceRestart) {
            # Service is either not running or ForceRestart is enabled — cycle it
            Try {
                Stop-Service  -Name $service -Force        -ErrorAction Continue
                Write-Output "$HEAD $service stopped."
                Start-Service -Name $service               -ErrorAction Continue
                Write-Output "$HEAD $service started."
            } Catch {
                Write-Error "$HEAD Error restarting '$service': $($_.Exception.Message)"
            }
        } Else {
            # Service is running and ForceRestart is disabled — leave it in place
            Write-Output "$HEAD $service is already running — skipping restart."
        }

        # Re-query status after the stop/start attempt
        $svc = Get-Service -Name $service -ErrorAction SilentlyContinue
        if ($svc.Status -eq 'Running') {
            $ServiceStarted++
        }

    } Else {
        Write-Warning "$HEAD Service '$service' not found on this system."
    }
}

# ── Result ────────────────────────────────────────────────────────────────────

if ($ServiceStarted -lt $ServiceTotal) {
    Write-Error "$HEAD FAILED. Only $ServiceStarted of $ServiceTotal service(s) are running after remediation."
    Exit 1
}

Write-Host "$HEAD SUCCESS. $ServiceStarted of $ServiceTotal service(s) running."
Exit 0