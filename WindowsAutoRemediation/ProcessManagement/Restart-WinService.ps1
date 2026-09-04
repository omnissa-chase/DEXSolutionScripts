<#
.NOTES
    Script Name  : Restart-WinService.ps1
    Data Type    : String
    Version      : 1.7.0.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-09-04
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
    $matched = @(Get-Service -ErrorAction SilentlyContinue |
                 Where-Object { $_.Name -like "*$ServiceName*" -or $_.DisplayName -like "*$ServiceName*" })

    if ($matched.Count -eq 0) {
        Write-Output "$HEAD Error: no service matched '$ServiceName'."
        $script:FailureCount++
        return
    }

    foreach ($svc in $matched) {
        # $svc is a ServiceController. Interpolating it directly prints the type
        # name rather than the service, so build the label from its properties.
        $label = "$($svc.DisplayName) ($($svc.Name))"

        if ($svc.Status -ne 'Running') {
            if ($PSCmdlet.ShouldProcess($label, 'Start service')) {
                try {
                    Start-Service -Name $svc.Name -ErrorAction Stop
                    Write-Output "$HEAD $label has been started."
                } catch {
                    $script:FailureCount++
                    Write-Output "$HEAD Error, $label could not be started: $($_.Exception.Message)"
                }
            } else {
                Write-Output "$HEAD WhatIf: would start $label."
            }
        }
        else {
            if ($PSCmdlet.ShouldProcess($label, 'Restart service')) {
                try {
                    Stop-Service -Name $svc.Name -Force -ErrorAction Stop
                    Start-Sleep -Milliseconds 1000
                    Start-Service -Name $svc.Name -ErrorAction Stop
                    Write-Output "$HEAD $label successfully restarted."
                } catch {
                    $script:FailureCount++
                    Write-Output "$HEAD Error, $label could not be restarted: $($_.Exception.Message)"
                }
            } else {
                Write-Output "$HEAD WhatIf: would restart $label."
            }
        }
    }
}

# -- entry point ---------------------------------------------------------------
# The param block lives inside the function deliberately. The Workspace ONE script
# engine does not recognise a param block at script scope, and $PSCmdlet is $null
# there, which makes every ShouldProcess call throw.
$SCRIPT_VERSION      = "1.7.0.0"
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

if ([string]::IsNullOrEmpty($env:ServiceName)) {
    Write-Output "$HEAD Error: ServiceName is not specified."
    Exit 1
}

Restart-WinService -ServiceName $env:ServiceName

if ($script:FailureCount -gt 0) { Exit 1 }
Exit 0
