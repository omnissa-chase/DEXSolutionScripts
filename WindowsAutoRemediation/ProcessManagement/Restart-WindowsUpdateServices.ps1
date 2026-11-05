<#
.SYNOPSIS
    Restarts Windows Update and related services to resolve stalled or broken
    update states.  NOTE:  THIS IS ALREADY HANDLED BY THE INVOKE-AUTOREMEDIATEWINDOWSUPDATE SCRIPT.

.PARAMETER ForceRestart
    When $true (default), the service is stopped and restarted even if it is
    already in a Running state. Set to $false to skip services that are
    already running.

.NOTES
    Script Name  : Restart-WindowsUpdateServices.ps1
    Version      : 1.6.2.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-05 (1.6.2.0: header and banner carry the file's real name; a Disabled
                   service is set back to its Windows default start type before it is started, since a
                   disabled update stack is the fault this script exists to repair; running dependents
                   that Stop-Service -Force takes down (cryptsvc carries AppIDSvc and applockerfltr) are
                   started again afterwards; the service calls use -ErrorAction Stop so the catch block
                   runs and the failure is counted; no leading blank line per result)
    Timeout      : 60 seconds

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

# ── Configuration ─────────────────────────────────────────────────────────────

$SCRIPT_VERSION = "1.6.2.0"

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
$services = @("wuauserv","bits","cryptsvc","msiserver")

# Windows default start type per service, applied when one has been Disabled (an update
# blocker's usual lever). Anything not listed is set to Manual.
$DefaultStartType = @{ "wuauserv" = "Manual"; "bits" = "Manual"; "cryptsvc" = "Automatic"; "msiserver" = "Manual" }

# ── Execution ─────────────────────────────────────────────────────────────────

# Generate a random 4-digit ID to correlate all log lines from this run
$RunEventId = ([Random]::new()).Next(1000, 9999)

Write-Output "[$RunEventId] Restart-WindowsUpdateServices v$SCRIPT_VERSION  Started @ $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"

# $HEAD prefix is prepended to every log line for easy grep/correlation
$HEAD = "[$RunEventId]"

$ServiceTotal   = 0
$ServiceStarted = 0

ForEach ($service in $services) {

    $svc = Get-Service -Name $service -ErrorAction SilentlyContinue

    If ($svc) {
        $ServiceTotal++

        # A Disabled service cannot be started; put it back on its Windows default first.
        If ($svc.StartType -eq 'Disabled') {
            $target = If ($DefaultStartType.ContainsKey($service)) { $DefaultStartType[$service] } Else { 'Manual' }
            If ($WhatIfPreference) {
                Write-Output "$HEAD WhatIf: would set $service from Disabled to $target."
            } Else {
                Try {
                    Set-Service -Name $service -StartupType $target -ErrorAction Stop
                    Write-Output "$HEAD $service was Disabled; startup type set to $target."
                } Catch {
                    Write-Output "$HEAD Error: $service is Disabled and the startup type could not be changed: $($_.Exception.Message)"
                }
            }
        }

        If ($svc.Status -ne 'Running' -or $ForceRestart) {
            # Service is either not running or ForceRestart is enabled — cycle it.
            # Stop-Service -Force takes running dependents down too (cryptsvc carries
            # AppIDSvc and applockerfltr, the AppLocker pair); start them again afterwards.
            $dependents = @($svc.DependentServices | Where-Object { $_.Status -eq 'Running' } | ForEach-Object { $_.Name })
            If ($WhatIfPreference) {
                Write-Output "$HEAD WhatIf: would restart $service$(If ($dependents.Count) { " and start its dependents again ($($dependents -join ', '))" })."
            } Else {
                Try {
                    If ($svc.Status -eq 'Running') {
                        Stop-Service -Name $service -Force -ErrorAction Stop
                        Write-Output "$HEAD $service stopped."
                    }
                    Start-Service -Name $service -ErrorAction Stop
                    Write-Output "$HEAD $service started."
                } Catch {
                    $detail = $_.Exception.Message
                    If ($_.Exception.InnerException) { $detail += " $($_.Exception.InnerException.Message)" }
                    Write-Output "$HEAD Error restarting '$service': $detail"
                }
                ForEach ($dep in $dependents) {
                    Try {
                        Start-Service -Name $dep -ErrorAction Stop
                        Write-Output "$HEAD Dependent service $dep started again."
                    } Catch {
                        Write-Output "$HEAD Dependent service $dep was stopped by the restart and did not start again: $($_.Exception.Message)"
                    }
                }
            }
        } Else {
            # Service is running and ForceRestart is disabled — leave it in place
            Write-Output "$HEAD $service is already running — skipping restart."
        }

        # Re-query status after the stop/start attempt (a WhatIf run counts the current state)
        $svc = Get-Service -Name $service -ErrorAction SilentlyContinue
        if ($svc.Status -eq 'Running' -or $WhatIfPreference) {
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

Write-Output "$HEAD SUCCESS. $ServiceStarted of $ServiceTotal service(s) running."
Exit 0