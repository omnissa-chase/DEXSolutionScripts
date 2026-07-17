<#
.NOTES
    Script Name  : performance_bitlockerstatus.ps1
    Data Type    : String 
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-07-10

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

Try{
    $blv = Get-BitLockerVolume -MountPoint 'C:'

    $rslt = [PSCustomObject]@{
        MountPoint           = $blv.MountPoint
        VolumeStatus         = $blv.VolumeStatus
        EncryptionPercentage = $blv.EncryptionPercentage
        ProtectionStatus     = $blv.ProtectionStatus
    }
    echo ($rslt | ConvertTo-Json -Compress)
}Catch{
    echo "$($_.Exception.Message)"
}
