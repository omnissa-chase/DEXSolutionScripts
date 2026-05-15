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
