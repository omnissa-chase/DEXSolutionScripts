<#
.SYNOPSIS
    Soft-locks the active console session on a managed device.

.DESCRIPTION
    Disconnects the active console session using tsdiscon.exe, which locks the
    screen without signing the user out. All running processes and unsaved work
    are preserved. Intended for use as a remote MDM command deployed through
    Omnissa Workspace ONE.

.NOTES
    Script Name  : DEX_Start-LockDeviceSoft.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-07-08
    Timeout      : 5 seconds

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

$LockDevice={
    [CmdletBinding(SupportsShouldProcess=$true)]
    param()
    if(-not $WhatIfPreference){
        tsdiscon.exe console
    }else{
        Write-Host "WhatIf: Locking machine, using soft lock."
    }
}
Try{   
    $rslt=Invoke-Command $LockDevice | Out-String
    echo $rslt
    Exit 0
}Catch{
    $rslt="An error has occured $($_.Exception.Message)"
}
Exit 1