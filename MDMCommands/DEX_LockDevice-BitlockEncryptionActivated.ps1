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
    /f and unsaved work is lost. The power-off is handed to the OS timer with a 15-second
    delay so the script exits first and UEM records Completed with the manage-bde output;
    the device then powers off on its own.

.NOTES
    Script Name  : DEX_LockDevice-BitlockEncryptionActivated.ps1
    Version      : 1.3.0
    Context      : System
    Timeout      : 15 seconds
    Last Modified: 2026-10-30 (1.3.0: power-off is deferred 15 s through shutdown.exe's own
                   timer so the script exits and Hub reports Completed before the device
                   goes down; 1.2.0 ran shutdown /t 0 in-process and UEM could only ever
                   show no result.)
                   2026-10-30 (1.2.0: refuses to power off unless Get-BitLockerVolume reports
                   protection On before and Off after the suspend, and treats "ERROR:" text from
                   manage-bde as a failure. 1.1.0 relied on the manage-bde exit code alone, and a
                   UEM run against an unencrypted VM still reached the shutdown.)
                   2026-10-28 (1.1.0: added header documenting intent, the catch block now
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
    # Guard: only power off when there is BitLocker protection to suspend. The exit code of
    # manage-bde alone is not a safe gate: on 2026-10-30 a VM that UEM reported as
    # BitLockerProtectionNotPresent still reached the shutdown line, so the state is checked
    # first and any "ERROR:" text from manage-bde is treated as a failure.
    $vol = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction Stop
    if ([string]$vol.ProtectionStatus -ne 'On') {
        throw "BitLocker protection is not on for C: (ProtectionStatus=$($vol.ProtectionStatus), VolumeStatus=$($vol.VolumeStatus)). Nothing to suspend; refusing to power off."
    }
    $out = & manage-bde.exe -protectors -disable C: 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -or $out -match 'ERROR:') { throw "manage-bde -protectors -disable C: returned $LASTEXITCODE. $out" }
    $after = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction Stop
    if ([string]$after.ProtectionStatus -ne 'Off') { throw "Protectors were not suspended (ProtectionStatus=$($after.ProtectionStatus)); refusing to power off." }
    $out
    # Deferred power-off: shutdown.exe returns at once and the OS owns the timer, so this
    # script exits and Hub records the result before the device goes down.
    & shutdown.exe /s /f /t 15 /c "Emergency lock-down: BitLocker protectors suspended, powering off." 2>&1
    if ($LASTEXITCODE -ne 0) { throw "shutdown /s /f /t 15 returned $LASTEXITCODE." }
    "Power-off scheduled in 15 seconds."
}

Try{
    $rslt=Invoke-Command $LockDevice | Out-String
    Write-Output $rslt
    Exit 0
}Catch{
    Write-Output "An error has occured: $($_.Exception.Message)"
}
Exit 1
