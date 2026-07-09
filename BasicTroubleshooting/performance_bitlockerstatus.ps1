<#
.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE in the repository root for full license terms (MIT).
#>

# Name: performance_bitlockerstatus
# Type: PowerShell 
# Context: System 
# Data Type: String 

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
