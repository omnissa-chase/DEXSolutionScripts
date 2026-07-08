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
    Author       : Chase Bradley
    Last Modified: 2026-07-08

    Workspace ONE Script Configuration:
      - Execution Context : System
      - Architecture      : Any
      - Timeout (seconds) : 5
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