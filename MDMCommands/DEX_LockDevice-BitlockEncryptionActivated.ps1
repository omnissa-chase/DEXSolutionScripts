<#
.SYNOPSIS
    Emergency lock-down: suspends the BitLocker protectors on C: and immediately powers the
    device off.

.DESCRIPTION
    Intended for device decommission or emergency scenarios where encryption must be
    suspended before power-off (for example a device being handed to a repair vendor that
    must boot without the recovery key). It is NOT a screen lock; use
    DEX_Start-LockDeviceSoft.ps1 to lock the console session.

    WARNING: after this runs the volume key is stored in the clear on disk until protectors
    are re-enabled with `manage-bde -protectors -enable C:`. All sessions are closed with
    /f and unsaved work is lost. The device powers off before UEM receives a result, so a
    UEM status of Failed or no result is expected.

.NOTES
    Script Name  : DEX_LockDevice-BitlockEncryptionActivated.ps1
    Version      : 1.1.0
    Context      : System
    Timeout      : 15 seconds
    Last Modified: 2026-10-28 (1.1.0: added header documenting intent, the catch block now
                   reports the error instead of swallowing it, native exit codes checked.)

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

$LockDevice={
    [CmdletBinding(SupportsShouldProcess=$true)]
    param()
    $out = & manage-bde.exe -protectors -disable C: 2>&1
    if ($LASTEXITCODE -ne 0) { throw "manage-bde -protectors -disable C: returned $LASTEXITCODE. $($out -join ' ')" }
    $out
    & shutdown.exe /s /f /t 0 2>&1
    if ($LASTEXITCODE -ne 0) { throw "shutdown /s /f /t 0 returned $LASTEXITCODE." }
}

Try{
    $rslt=Invoke-Command $LockDevice | Out-String
    Write-Output $rslt
    Exit 0
}Catch{
    Write-Output "An error has occured: $($_.Exception.Message)"
}
Exit 1
