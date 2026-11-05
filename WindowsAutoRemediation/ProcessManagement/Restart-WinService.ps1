<#
.NOTES
    Script Name  : Restart-WinService.ps1
    Data Type    : String
    Version      : 1.7.1.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-05 (1.7.1.0: exact name or display-name match first, wildcard only as a
                   fallback; a Disabled service is reported as such instead of the generic "Cannot
                   start service"; running dependents that Stop-Service -Force takes down are started
                   again after the restart; error text includes the inner exception; no leading blank
                   line per result. A Disabled service is still left alone by design: Disabled is an
                   administrative decision this script does not override.)
    Timeout      : 15 seconds

    Inputs (UEM script-object variables):
      ServiceName   Required. Matched against the service short name or display name.
      WhatIf        Optional. Only an explicit, parseable "true" enables a dry run.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>
function Restart-WinService {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param([Parameter(Mandatory=$true)][string]$ServiceName)

    # Match the short name OR the display name. Matching DisplayName alone stops
    # 'wuauserv' resolving, which would silently break every existing assignment.
    # SilentlyContinue because a few protected services (PrintNotify, WaaSMedicSvc)
    # always throw PermissionDenied and would otherwise noise up every run.
    # An exact match wins; the wildcard match is only a fallback, so 'Spooler' can no
    # longer also catch a dependent whose name happens to contain the same word.
    # Never enumerate every service: under PowerShell 7 Get-Service aborts the whole
    # enumeration on a protected service (McmSvc: "Cannot open ... service") even with
    # -ErrorAction SilentlyContinue, and the script then reported "no service matched".
    # Exact lookups go straight to the name; the wildcard fallback resolves names through
    # CIM, which does not trip over service ACLs.
    $matched = @()
    try { $matched = @(Get-Service -Name $ServiceName -ErrorAction Stop) } catch { $matched = @() }
    if ($matched.Count -eq 0) { try { $matched = @(Get-Service -DisplayName $ServiceName -ErrorAction Stop) } catch { $matched = @() } }
    if ($matched.Count -eq 0) {
        $wql   = ($ServiceName -replace "'", "''") -replace '[%_\[\]^]', '[$0]'
        $names = @(Get-CimInstance -ClassName Win32_Service -Filter "Name LIKE '%$wql%' OR DisplayName LIKE '%$wql%'" -ErrorAction SilentlyContinue |
                   Select-Object -ExpandProperty Name)
        $matched = @(foreach ($n in $names) { try { Get-Service -Name $n -ErrorAction Stop } catch { } })
    }

    if ($matched.Count -eq 0) {
        Write-Output "$HEAD Error: no service matched '$ServiceName'."
        $script:FailureCount++
        return
    }

    foreach ($svc in $matched) {
        # Re-read: an earlier match's -Force stop may have changed this one's state.
        $svc = Get-Service -Name $svc.Name -ErrorAction SilentlyContinue
        if (-not $svc) { continue }

        # $svc is a ServiceController. Interpolating it directly prints the type
        # name rather than the service, so build the label from its properties.
        $label = "$($svc.DisplayName) ($($svc.Name))"

        if ($svc.Status -ne 'Running') {
            if ($svc.StartType -eq 'Disabled') {
                # Left alone by design; say so instead of the generic "Cannot start service".
                $script:FailureCount++
                Write-Output "$HEAD Error, $label could not be started: its startup type is Disabled. Change the startup type first; this script does not override an administrative Disabled."
                continue
            }
            if ($PSCmdlet.ShouldProcess($label, 'Start service')) {
                try {
                    Start-Service -Name $svc.Name -ErrorAction Stop
                    Write-Output "$HEAD $label has been started."
                } catch {
                    $script:FailureCount++
                    Write-Output "$HEAD Error, $label could not be started: $(Get-ErrorText $_)"
                }
            } else {
                Write-Output "$HEAD WhatIf: would start $label."
            }
        }
        else {
            if ($PSCmdlet.ShouldProcess($label, 'Restart service')) {
                # Stop-Service -Force takes running dependents down with the target (Print
                # Spooler carries Fax and PrintNotify where present); start them again after.
                $dependents = @($svc.DependentServices | Where-Object { $_.Status -eq 'Running' } | ForEach-Object { $_.Name })
                try {
                    Stop-Service -Name $svc.Name -Force -ErrorAction Stop
                    Start-Sleep -Milliseconds 1000
                    Start-Service -Name $svc.Name -ErrorAction Stop
                    Write-Output "$HEAD $label successfully restarted."
                } catch {
                    $script:FailureCount++
                    Write-Output "$HEAD Error, $label could not be restarted: $(Get-ErrorText $_)"
                }
                foreach ($dep in $dependents) {
                    try {
                        Start-Service -Name $dep -ErrorAction Stop
                        Write-Output "$HEAD Dependent service $dep started again."
                    } catch {
                        # Not a failure of the target: some dependents (PrintNotify) are trigger-started and refuse a manual start.
                        Write-Output "$HEAD Dependent service $dep was stopped by the restart and did not start again: $(Get-ErrorText $_)"
                    }
                }
            } else {
                Write-Output "$HEAD WhatIf: would restart $label."
            }
        }
    }
}

function Get-ErrorText {
    # The service cmdlets put the useful cause in InnerException ("Cannot start service" is the wrapper).
    param($ErrorRecord)
    $text = $ErrorRecord.Exception.Message
    $inner = $ErrorRecord.Exception.InnerException
    while ($inner) { $text += " $($inner.Message)"; $inner = $inner.InnerException }
    return $text
}

# -- entry point ---------------------------------------------------------------
# The param block lives inside the function deliberately. The Workspace ONE script
# engine does not recognise a param block at script scope, and $PSCmdlet is $null
# there, which makes every ShouldProcess call throw.
$SCRIPT_VERSION      = "1.7.1.0"
$script:FailureCount = 0
$RunEventId          = ([Random]::new()).Next(1000,9999)
$HEAD                = "[$RunEventId]"

Write-Output "[$RunEventId] Executing script, $SCRIPT_VERSION. Started @ '$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))'"

# Default to a LIVE run. Only an explicit, parseable "true" enables WhatIf, so a
# missing or malformed value can never turn remediation into a silent no-op.
$WhatIfPreference = $false
if ($env:WhatIf) {
    try   { $WhatIfPreference = [System.Convert]::ToBoolean($env:WhatIf) }
    catch { $WhatIfPreference = $false }
}

if ([string]::IsNullOrEmpty($env:ServiceName)) {
    Write-Output "$HEAD Error: ServiceName is not specified."
    Exit 1
}

Restart-WinService -ServiceName $env:ServiceName

if ($script:FailureCount -gt 0) { Exit 1 }
Exit 0
