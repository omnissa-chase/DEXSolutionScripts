#Requires -Version 5.1
<#
.SYNOPSIS
    Enables the optional Windows event logs required for full logon-phase coverage.

.DESCRIPTION
    Printer mapping and logon-triggered scheduled task timings are only visible in
    two logs that ship disabled by default:
      - Microsoft-Windows-PrintService/Operational   (EID 300 start, EID 306 finish)
      - Microsoft-Windows-TaskScheduler/Operational   (EID 100 start, EID 102 finish)

    Run this once per device image (or push it as a one-time UEM script) before
    relying on logon_duration_measure.ps1 or Measure-LogonDuration.ps1 for those two
    metrics -- without it they report the LogDisabled sentinel instead of a value.

    Idempotent: writes a completion timestamp to the same registry marker used by
    Measure-LogonDuration.ps1's own -DeployMode ConfigureLogging, so running either
    script first satisfies both. Safe to re-run; already-enabled logs are reported
    and skipped unless -Force is supplied.

.PARAMETER Force
    Re-checks and re-enables both logs even if the completion marker already exists.

.NOTES
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-12
    Requires     : Local administrator / SYSTEM context (wevtutil.exe sl requires elevation).

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>
function Enable-LogonAuditLogs {
param(
    [switch]$Force
)

$script:RegPath = 'HKLM:\Software\AirWatch\Extensions\DEXRecords\LogonDuration'

if (-not $Force) {
    $marker = (Get-ItemProperty -Path $script:RegPath -Name 'AuditLogsConfiguredAt' -ErrorAction SilentlyContinue).AuditLogsConfiguredAt
    if (-not [string]::IsNullOrWhiteSpace($marker)) {
        Write-Output "Audit logs already configured at $marker. Skipping. Use -Force to re-run."
        exit 0
    }
}

$targets = @(
    [PSCustomObject]@{
        LogName     = 'Microsoft-Windows-PrintService/Operational'
        Description = 'Printer mapping duration (EID 300 start, EID 306 finish)'
    }
    [PSCustomObject]@{
        LogName     = 'Microsoft-Windows-TaskScheduler/Operational'
        Description = 'Logon scheduled task duration (EID 100 start, EID 102 finish)'
    }
)

$failures = 0

Write-Output ''
Write-Output '=== DEX Audit Log Configuration ==='

foreach ($target in $targets) {
    $log = Get-WinEvent -ListLog $target.LogName -ErrorAction SilentlyContinue

    if (-not $log) {
        Write-Output "  [NOT FOUND] $($target.LogName)"
        Write-Output "              This log does not exist on this system. Skipping."
        continue
    }

    if ($log.IsEnabled) {
        Write-Output "  [OK]        $($target.LogName)"
        Write-Output "              Already enabled -- $($target.Description)"
    } else {
        try {
            wevtutil.exe sl $target.LogName /e:true 2>&1 | Out-Null
            # Re-query to confirm
            $verify = Get-WinEvent -ListLog $target.LogName -ErrorAction SilentlyContinue
            if ($verify.IsEnabled) {
                Write-Output "  [ENABLED]   $($target.LogName)"
                Write-Output "              Now enabled -- $($target.Description)"
            } else {
                $failures++
                Write-Output "  [FAILED]    $($target.LogName)"
                Write-Output "              wevtutil returned success but log still reports disabled."
            }
        } catch {
            $failures++
            Write-Output "  [ERROR]     $($target.LogName)"
            Write-Output "              $_"
        }
    }
    Write-Output ''
}

# Shared marker: whichever script (this one, or Measure-LogonDuration.ps1
# -DeployMode ConfigureLogging) runs first makes the other a no-op.
if (-not (Test-Path $script:RegPath)) {
    New-Item -Path $script:RegPath -Force | Out-Null
}
Set-ItemProperty -Path $script:RegPath -Name 'AuditLogsConfiguredAt' `
    -Value (Get-Date).ToString('yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture) `
    -Type String -Force -ErrorAction SilentlyContinue

Write-Output '=== Configuration complete ==='

if ($failures -gt 0) {
    Write-Output "$failures of $($targets.Count) log(s) could not be enabled. Re-run elevated if this persists."
    exit 1
}

exit 0
}

# -- entry point ---------------------------------------------------------------
# The param block sits inside the function deliberately. The Workspace ONE script
# engine does not recognise a param block at script scope, and $PSCmdlet is $null
# there, which makes every ShouldProcess call throw. Inputs arrive as environment
# variables and are bound to the function's parameters below.

Enable-LogonAuditLogs
Exit 0
